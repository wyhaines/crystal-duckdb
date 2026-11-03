# :nodoc:
# One tree per result, owning every logical type it obtains. Adding a type
# means adding a node at build, with its own read_value and bind behaviour.
abstract class DuckDB::ColumnReader
  @logical_type = Pointer(Void).null.as(LibDuckDB::LogicalType)
  getter type : LibDuckDB::Type = LibDuckDB::Type::INVALID
  getter name : String = ""
  getter children = [] of ColumnReader
  getter child_names = [] of String
  getter width = 0_u8
  getter scale = 0_u8
  getter storage_type = LibDuckDB::Type::INVALID
  getter array_size = 0_u64
  getter vector = VectorView.empty
  getter row_count = 0_i64
  getter dictionary = [] of String

  def self.build(logical_type : LibDuckDB::LogicalType, name : String, deduplicate_strings : Bool = false) : ColumnReader
    {% begin %}
    case LibDuckDB.get_type_id(logical_type)
    {% for kind, scalar in {BOOLEAN: Bool, TINYINT: Int8, SMALLINT: Int16, INTEGER: Int32, BIGINT: Int64, UTINYINT: UInt8, USMALLINT: UInt16, UINTEGER: UInt32, UBIGINT: UInt64, HUGEINT: Int128, UHUGEINT: UInt128, UUID: UUID, DECIMAL: DuckDB::Decimal, BIGNUM: DuckDB::BigNum, TIME_TZ: DuckDB::TimeTZ, FLOAT: Float32, DOUBLE: Float64, VARCHAR: String, BLOB: Bytes, DATE: DuckDB::Date, TIME: DuckDB::TimeOfDay, TIMESTAMP: DuckDB::Timestamp, INTERVAL: DuckDB::Interval} %}
    when .{{kind.id.downcase}}?
      ScalarColumnReader({{scalar}}).new(logical_type, name, deduplicate_strings)
    {% end %}
    when .enum?, .bit?
      ScalarColumnReader(String).new(logical_type, name, deduplicate_strings)
    when .geometry?
      ScalarColumnReader(Bytes).new(logical_type, name, deduplicate_strings)
    when .time_ns?
      ScalarColumnReader(TimeOfDay).new(logical_type, name, deduplicate_strings)
    when .timestamp_s?, .timestamp_ms?, .timestamp_ns?, .timestamp_tz?, .timestamp_tz_ns?
      ScalarColumnReader(Timestamp).new(logical_type, name, deduplicate_strings)
    when .list?, .array?
      ListColumnReader.new(logical_type, name, deduplicate_strings)
    when .struct?
      StructColumnReader.new(logical_type, name, deduplicate_strings)
    when .map?
      MapColumnReader.new(logical_type, name, deduplicate_strings)
    when .union?
      UnionColumnReader.new(logical_type, name, deduplicate_strings)
    else
      UnsupportedColumnReader.new(logical_type, name, deduplicate_strings)
    end
    {% end %}
  end

  def initialize(@logical_type : LibDuckDB::LogicalType, @name : String, deduplicate_strings : Bool = false)
    @type = LibDuckDB.get_type_id(@logical_type)
    case @type
    when .decimal?
      @width = LibDuckDB.decimal_width(@logical_type)
      @scale = LibDuckDB.decimal_scale(@logical_type)
      @storage_type = LibDuckDB.decimal_internal_type(@logical_type)
    when .enum?
      @storage_type = LibDuckDB.enum_internal_type(@logical_type)
      LibDuckDB.enum_dictionary_size(@logical_type).times do |index|
        ptr = LibDuckDB.enum_dictionary_value(@logical_type, index.to_u64)
        begin
          @dictionary << String.new(ptr)
        ensure
          LibDuckDB.free(ptr)
        end
      end
    when .list?, .map?
      # MAP's physical child is STRUCT(key, value).
      @children << ColumnReader.build(LibDuckDB.list_type_child_type(@logical_type), "#{@name}[]", deduplicate_strings)
    when .array?
      @array_size = LibDuckDB.array_type_array_size(@logical_type)
      @children << ColumnReader.build(LibDuckDB.array_type_child_type(@logical_type), "#{@name}[]", deduplicate_strings)
    when .struct?
      LibDuckDB.struct_type_child_count(@logical_type).times do |index|
        ptr = LibDuckDB.struct_type_child_name(@logical_type, index)
        begin
          child_name = String.new(ptr)
          @child_names << child_name
          @children << ColumnReader.build(LibDuckDB.struct_type_child_type(@logical_type, index), "#{@name}.#{child_name}", deduplicate_strings)
        ensure
          LibDuckDB.free(ptr)
        end
      end
    when .union?
      LibDuckDB.union_type_member_count(@logical_type).times do |index|
        ptr = LibDuckDB.union_type_member_name(@logical_type, index)
        begin
          child_name = String.new(ptr)
          @child_names << child_name
          @children << ColumnReader.build(LibDuckDB.union_type_member_type(@logical_type, index), "#{@name}.#{child_name}", deduplicate_strings)
        ensure
          LibDuckDB.free(ptr)
        end
      end
    end
  rescue ex
    close
    raise ex
  end

  def bind(@vector : VectorView, @row_count : Int64)
    case @type
    when .list?, .map?
      @children[0].bind(VectorView.new(LibDuckDB.list_vector_get_child(@vector.handle)), LibDuckDB.list_vector_get_size(@vector.handle).to_i64)
    when .array?
      @children[0].bind(VectorView.new(LibDuckDB.array_vector_get_child(@vector.handle)), @row_count * @array_size.to_i64)
    when .struct?, .union?
      @children.each_with_index do |child, index|
        # UNION is a STRUCT with a tag preceding its members.
        offset = @type.union? ? 1 : 0
        child.bind(VectorView.new(LibDuckDB.struct_vector_get_child(@vector.handle, (index + offset).to_u64)), @row_count)
      end
    end
  end

  def close
    @children.each &.close
    LibDuckDB.destroy_logical_type(pointerof(@logical_type)) unless @logical_type.null?
    @vector = VectorView.empty
  end

  abstract def read(row : Int64) : DuckDB::Value

  # Build typed containers directly, recursively applying scalar conversions.
  def read_as(row : Int64, type : T.class, column_index : Int32 = 0) : T forall T
    {% if T.nilable? && T.union_types.size == 2 %}
      return nil if @type.sqlnull? || @vector.null?(row)
      read_as(row, {{T.union_types.reject { |t| t == Nil }[0]}}, column_index)
    {% else %}
      reader = self
      {% if T < Array %}
        if reader.is_a?(ListColumnReader) && !@vector.null?(row)
          return reader.read_array(row, {{T.type_vars[0]}}, column_index)
        end
      {% elsif T < Hash %}
        {% if T.type_vars[0] == String %}
          if reader.is_a?(StructColumnReader) && !@vector.null?(row)
            return reader.read_hash(row, {{T.type_vars[1]}}, column_index)
          end
        {% end %}
        if reader.is_a?(MapColumnReader) && !@vector.null?(row)
          return reader.read_map(row, {{T.type_vars[0]}}, {{T.type_vars[1]}}, column_index)
        end
      {% end %}
      value = read(row)
      {% if T == ::Time %}
        return value.to_time if value.is_a?(Date) || value.is_a?(Timestamp)
      {% elsif T == String %}
        if value.is_a?(Decimal) || value.is_a?(UUID) || value.is_a?(Date) || value.is_a?(TimeOfDay) || value.is_a?(TimeTZ) || value.is_a?(Timestamp) || value.is_a?(Interval) || value.is_a?(BigNum)
          return value.to_s
        end
      {% end %}
      return value if value.is_a?(T)
      raise DB::ColumnTypeMismatchError.new(context: "DuckDB::ResultSet#read", column_index: column_index,
        column_name: @name, column_type: value.class.to_s, expected_type: T.to_s)
    {% end %}
  end
end

# :nodoc:
class DuckDB::ScalarColumnReader(T) < DuckDB::ColumnReader
  @string_cache : StringCache? = nil

  def initialize(logical_type : LibDuckDB::LogicalType, name : String, deduplicate_strings : Bool = false)
    super(logical_type, name, deduplicate_strings)
    {% if T == String %}
      @string_cache = StringCache.new if deduplicate_strings && @type.varchar?
    {% end %}
  end

  def close
    @string_cache.try &.clear
    @string_cache = nil
    super
  end

  def read_value(row : Int64) : T
    {% if T == Bool %}
      @vector.get(row, UInt8) != 0
    {% elsif T == String %}
      case @type
      when .enum?
        index = case @storage_type
                when .utinyint? then @vector.get(row, UInt8).to_u32
                when .usmallint? then @vector.get(row, UInt16).to_u32
                else @vector.get(row, UInt32)
                end
        @dictionary[index]
      when .bit?
        bytes, length = @vector.string_data(row)
        padding = bytes[0].to_i
        String.build do |io|
          (length.to_i - 1).times do |index|
            (index == 0 ? padding : 0).upto(7) do |bit|
              io << ((bytes[index + 1] & (1 << (7 - bit))) == 0 ? '0' : '1')
            end
          end
        end
      else
        if cache = @string_cache
          cache.read(@vector, row)
        else
          @vector.string(row)
        end
      end
    {% elsif T == Bytes %}
      @vector.blob(row)
    {% elsif T == DuckDB::Date %}
      DuckDB::Date.new(@vector.get(row, Int32))
    {% elsif T == DuckDB::TimeOfDay %}
      raw = @vector.get(row, Int64)
      @type.time_ns? ? TimeOfDay.from_nanoseconds(raw) : TimeOfDay.new(raw)
    {% elsif T == DuckDB::Timestamp %}
      Timestamp.from_raw(@vector.get(row, Int64), @type)
    {% elsif T == DuckDB::Interval %}
      value = @vector.get(row, LibDuckDB::Interval)
      DuckDB::Interval.new(value.micros, value.days, value.months)
    {% elsif T == DuckDB::Decimal %}
      value = case @storage_type
              when .smallint? then @vector.get(row, Int16).to_i128
              when .integer? then @vector.get(row, Int32).to_i128
              when .bigint? then @vector.get(row, Int64).to_i128
              else HugeIntHelper.huge_to_i128(@vector.get(row, LibDuckDB::HugeInt))
              end
      Decimal.new(value, @width, @scale)
    {% elsif T == UUID %}
      raw = HugeIntHelper.huge_to_i128(@vector.get(row, LibDuckDB::HugeInt)).to_u128! ^ (1_u128 << 127)
      UUID.new(StaticArray(UInt8, 16).new { |i| (raw >> ((15 - i) * 8)).to_u8! })
    {% elsif T == UInt128 %}
      HugeIntHelper.uhuge_to_u128(@vector.get(row, LibDuckDB::UHugeInt))
    {% elsif T == DuckDB::TimeTZ %}
      value = LibDuckDB.from_time_tz(@vector.get(row, LibDuckDB::TimeTZ))
      TimeTZ.new(TimeOfDay.new(value.time.hour.to_i32, value.time.min.to_i32, value.time.sec.to_i32, value.time.micros), value.offset)
    {% elsif T == DuckDB::BigNum %}
      BigNum.new(@vector.blob(row))
    {% elsif T == Int128 %}
      value = @vector.get(row, LibDuckDB::HugeInt)
      (value.upper.to_i128 << 64) | value.lower.to_i128
    {% else %}
      @vector.get(row, T)
    {% end %}
  end

  def read(row : Int64) : DuckDB::Value
    @vector.null?(row) ? nil : read_value(row)
  end
end

# :nodoc:
class DuckDB::UnsupportedColumnReader < DuckDB::ColumnReader
  def read(row : Int64) : DuckDB::Value
    return nil if @type.sqlnull? || @vector.null?(row)
    if @type.variant?
      raise Exception.new("Unsupported DuckDB type VARIANT in column '#{@name}': the stable v1 C API exposes no VARIANT vector layout or accessors; cast to a concrete SQL type")
    end
    raise Exception.new("Unsupported DuckDB type #{@type} in column '#{@name}'")
  end
end

# :nodoc:
class DuckDB::ListColumnReader < DuckDB::ColumnReader
  def entry(row : Int64) : Tuple(Int64, Int32)
    if @type.array?
      {row * @array_size.to_i64, @array_size.to_i32}
    else
      entry = @vector.get(row, LibDuckDB::ListEntry)
      {entry.offset.to_i64, entry.length.to_i32}
    end
  end

  def read_array(row : Int64, type : T.class, column_index : Int32) : Array(T) forall T
    offset, length = entry(row)
    Array(T).new(length) { |i| @children[0].read_as(offset + i, type, column_index) }
  end

  def read(row : Int64) : DuckDB::Value
    return nil if @vector.null?(row)
    offset, length = entry(row)
    result = Array(DuckDB::Value).new(length)
    length.times { |i| result << @children[0].read(offset + i) }
    result
  end
end

# :nodoc:
class DuckDB::StructColumnReader < DuckDB::ColumnReader
  def read_hash(row : Int64, type : T.class, column_index : Int32) : Hash(String, T) forall T
    result = Hash(String, T).new
    @children.each_with_index { |child, i| result[@child_names[i]] = child.read_as(row, type, column_index) }
    result
  end

  def read(row : Int64) : DuckDB::Value
    return nil if @vector.null?(row)
    result = Hash(String, Value).new
    @children.each_with_index { |child, i| result[@child_names[i]] = child.read(row) }
    result
  end
end

# :nodoc:
class DuckDB::MapColumnReader < DuckDB::ColumnReader
  def read_map(row : Int64, key_type : K.class, value_type : V.class, column_index : Int32) : Hash(K, V) forall K, V
    entry = @vector.get(row, LibDuckDB::ListEntry)
    keys, values = @children[0].children
    result = Hash(K, V).new
    entry.length.to_i32.times do |i|
      index = entry.offset.to_i64 + i
      result[keys.read_as(index, key_type, column_index)] = values.read_as(index, value_type, column_index)
    end
    result
  end

  def read(row : Int64) : DuckDB::Value
    return nil if @vector.null?(row)
    read_map(row, Value, Value, 0)
  end
end

# :nodoc:
class DuckDB::UnionColumnReader < DuckDB::ColumnReader
  @tag = VectorView.empty

  def bind(vector : VectorView, row_count : Int64)
    super(vector, row_count)
    @tag = VectorView.new(LibDuckDB.struct_vector_get_child(vector.handle, 0_u64))
  end

  def read(row : Int64) : DuckDB::Value
    return nil if @vector.null?(row) || @tag.null?(row)
    @children[@tag.get(row, UInt8)].read(row)
  end
end
