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
  getter vector = Vector.empty

  def self.build(logical_type : LibDuckDB::LogicalType, name : String) : ColumnReader
    {% begin %}
    case LibDuckDB.get_type_id(logical_type)
    {% for kind, scalar in {BOOLEAN: Bool, TINYINT: Int8, SMALLINT: Int16, INTEGER: Int32, BIGINT: Int64, UTINYINT: UInt8, USMALLINT: UInt16, UINTEGER: UInt32, UBIGINT: UInt64, HUGEINT: Int128, FLOAT: Float32, DOUBLE: Float64, VARCHAR: String, BLOB: Bytes, DATE: DuckDB::Date, TIME: DuckDB::TimeOfDay, TIMESTAMP: DuckDB::Timestamp, INTERVAL: DuckDB::Interval} %}
    when .{{kind.id.downcase}}?
      ScalarColumnReader({{scalar}}).new(logical_type, name)
    {% end %}
    else
      UnsupportedColumnReader.new(logical_type, name)
    end
    {% end %}
  end

  def initialize(@logical_type : LibDuckDB::LogicalType, @name : String)
    @type = LibDuckDB.get_type_id(@logical_type)
    case @type
    when .decimal?
      @width = LibDuckDB.decimal_width(@logical_type)
      @scale = LibDuckDB.decimal_scale(@logical_type)
      @storage_type = LibDuckDB.decimal_internal_type(@logical_type)
    when .enum?
      @storage_type = LibDuckDB.enum_internal_type(@logical_type)
    when .list?, .map?
      # MAP's physical child is STRUCT(key, value).
      @children << ColumnReader.build(LibDuckDB.list_type_child_type(@logical_type), "#{@name}[]")
    when .array?
      @array_size = LibDuckDB.array_type_array_size(@logical_type)
      @children << ColumnReader.build(LibDuckDB.array_type_child_type(@logical_type), "#{@name}[]")
    when .struct?
      LibDuckDB.struct_type_child_count(@logical_type).times do |index|
        ptr = LibDuckDB.struct_type_child_name(@logical_type, index)
        begin
          child_name = String.new(ptr)
          @child_names << child_name
          @children << ColumnReader.build(LibDuckDB.struct_type_child_type(@logical_type, index), "#{@name}.#{child_name}")
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
          @children << ColumnReader.build(LibDuckDB.union_type_member_type(@logical_type, index), "#{@name}.#{child_name}")
        ensure
          LibDuckDB.free(ptr)
        end
      end
    end
  rescue ex
    close
    raise ex
  end

  def bind(@vector : Vector)
    case @type
    when .list?, .map?
      @children[0].bind(Vector.new(LibDuckDB.list_vector_get_child(@vector.handle)))
    when .array?
      @children[0].bind(Vector.new(LibDuckDB.array_vector_get_child(@vector.handle)))
    when .struct?, .union?
      @children.each_with_index do |child, index|
        # UNION is a STRUCT with a tag preceding its members.
        offset = @type.union? ? 1 : 0
        child.bind(Vector.new(LibDuckDB.struct_vector_get_child(@vector.handle, (index + offset).to_u64)))
      end
    end
  end

  def close
    @children.each &.close
    LibDuckDB.destroy_logical_type(pointerof(@logical_type)) unless @logical_type.null?
    @vector = Vector.empty
  end

  abstract def read(row : Int64) : DuckDB::Any
end

# :nodoc:
class DuckDB::ScalarColumnReader(T) < DuckDB::ColumnReader
  def read_value(row : Int64) : T
    {% if T == Bool %}
      @vector.get(row, UInt8) != 0
    {% elsif T == String %}
      @vector.string(row)
    {% elsif T == Bytes %}
      @vector.blob(row)
    {% elsif T == DuckDB::Date %}
      DuckDB::Date.new(@vector.get(row, Int32))
    {% elsif T == DuckDB::TimeOfDay %}
      DuckDB::TimeOfDay.new(@vector.get(row, Int64))
    {% elsif T == DuckDB::Timestamp %}
      DuckDB::Timestamp.new(@vector.get(row, Int64))
    {% elsif T == DuckDB::Interval %}
      value = @vector.get(row, LibDuckDB::Interval)
      DuckDB::Interval.new(value.micros, value.days, value.months)
    {% elsif T == Int128 %}
      value = @vector.get(row, LibDuckDB::HugeInt)
      (value.upper.to_i128 << 64) | value.lower.to_i128
    {% else %}
      @vector.get(row, T)
    {% end %}
  end

  def read(row : Int64) : DuckDB::Any
    @vector.null?(row) ? nil : read_value(row)
  end
end

# :nodoc:
class DuckDB::UnsupportedColumnReader < DuckDB::ColumnReader
  def read(row : Int64) : DuckDB::Any
    return nil if @type.sqlnull?
    raise Exception.new("Unsupported DuckDB type #{@type} in column '#{@name}'")
  end
end
