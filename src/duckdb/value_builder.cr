require "c/dlfcn"

# :nodoc:
# Resolve the optional 2.0 constructor without a link-time reference to it.
module DuckDB::TimestampTZNS
  @@mutex = Mutex.new
  @@resolved = false
  @@constructor : Proc(LibDuckDB::TimestampNS, LibDuckDB::Value)?

  def self.create(nanos : Int64) : LibDuckDB::Value
    constructor = @@mutex.synchronize do
      unless @@resolved
        pointer = LibC.dlsym(LibC::RTLD_DEFAULT, "duckdb_create_timestamp_tz_ns")
        @@constructor = Proc(LibDuckDB::TimestampNS, LibDuckDB::Value).new(pointer, Pointer(Void).null) unless pointer.null?
        @@resolved = true
      end
      @@constructor
    end
    unless constructor
      raise Exception.new("Nanosecond TIMESTAMP_TZ binding/appending is unavailable: requires DuckDB 2.0's duckdb_create_timestamp_tz_ns")
    end
    constructor.call(LibDuckDB::TimestampNS.new(nanos: nanos))
  end
end

# :nodoc:
# An arena for a single conversion. Constructors copy their inputs. All values
# and owned types stay alive until construction ends, including borrowed types
# obtained with get_value_type. Only the finished root leaves the arena.
class DuckDB::ValueBuilder
  # :nodoc:
  # Internal marker: only conversion failures may refresh prepared metadata.
  class ConversionError < DuckDB::Exception
  end

  NULL_TYPE = Pointer(Void).null.as(LibDuckDB::LogicalType)
  @values = [] of LibDuckDB::Value
  @types = [] of LibDuckDB::LogicalType

  def self.build(value, destination : LibDuckDB::LogicalType = NULL_TYPE) : LibDuckDB::Value
    builder = new
    begin
      root = builder.convert(value, destination)
      builder.release(root)
      root
    rescue ex : DuckDB::Exception
      raise ex if ex.is_a?(ConversionError)
      raise ConversionError.new(ex.message, cause: ex)
    rescue ex : ArgumentError | OverflowError
      raise ConversionError.new(ex.message, cause: ex)
    ensure
      builder.close
    end
  end

  def release(value)
    @values.delete(value)
  end

  def close
    @values.reverse_each { |value| LibDuckDB.destroy_value(pointerof(value)) }
    @types.reverse_each { |type| LibDuckDB.destroy_logical_type(pointerof(type)) }
    @values.clear
    @types.clear
  end

  private def own(value : LibDuckDB::Value) : LibDuckDB::Value
    raise ConversionError.new("Could not construct DuckDB value (check child types, ranges and UTF-8)") if value.null?
    @values << value
    value
  end

  private def own_type(type : LibDuckDB::LogicalType) : LibDuckDB::LogicalType
    raise ConversionError.new("Could not construct DuckDB logical type") if type.null?
    @types << type
    type
  end

  private def type_id(type)
    type.null? ? LibDuckDB::Type::INVALID : LibDuckDB.get_type_id(type)
  end

  private def resolved?(type)
    case type_id(type)
    when .invalid?, .any?, .sqlnull?, .string_literal?, .integer_literal? then false
    else                                                                       true
    end
  end

  def convert(value : T, destination : LibDuckDB::LogicalType = NULL_TYPE) : LibDuckDB::Value forall T
    {% if T.union? %}
      # Keep recursive aliases intact at each dispatch. Passing a widened union
      # to Hash/Enumerable generic methods loses alias identity on Crystal 1.22.
      {% for member in T.union_types %}
        return convert(value.as({{member}}), destination) if value.is_a?({{member}})
      {% end %}
      raise ConversionError.new("Unsupported DuckDB value")
    {% else %}
      return own(LibDuckDB.create_null_value) if value.nil?
      if type_id(destination).union?
        child = convert(value)
        actual = LibDuckDB.get_value_type(child)
        matches = [] of UInt64
        LibDuckDB.union_type_member_count(destination).times do |index|
          member = own_type(LibDuckDB.union_type_member_type(destination, index))
          matches << index if same_type?(actual, member)
        end
        unless matches.size == 1
          raise ConversionError.new("UNION requires one exact logical-type match; found #{matches.size} for #{type_id(actual)}")
        end
        return own(LibDuckDB.create_union_value(destination, matches[0], child))
      end
      build_value(value, resolved?(destination) ? destination : NULL_TYPE)
    {% end %}
  end

  # Compare full logical types for UNION selection, including DECIMAL metadata,
  # fixed lengths, names and recursively nested member types.
  private def same_type?(left, right) : Bool
    id = type_id(left)
    return false unless id == type_id(right)
    case id
    when .decimal?
      LibDuckDB.decimal_width(left) == LibDuckDB.decimal_width(right) && LibDuckDB.decimal_scale(left) == LibDuckDB.decimal_scale(right)
    when .list?, .array?
      if id.array?
        return false unless LibDuckDB.array_type_array_size(left) == LibDuckDB.array_type_array_size(right)
        same_type?(own_type(LibDuckDB.array_type_child_type(left)), own_type(LibDuckDB.array_type_child_type(right)))
      else
        same_type?(own_type(LibDuckDB.list_type_child_type(left)), own_type(LibDuckDB.list_type_child_type(right)))
      end
    when .map?
      same_type?(own_type(LibDuckDB.map_type_key_type(left)), own_type(LibDuckDB.map_type_key_type(right))) &&
        same_type?(own_type(LibDuckDB.map_type_value_type(left)), own_type(LibDuckDB.map_type_value_type(right)))
    when .struct?
      count = LibDuckDB.struct_type_child_count(left)
      return false unless count == LibDuckDB.struct_type_child_count(right)
      count.times do |i|
        return false unless field_name(left, i) == field_name(right, i)
        return false unless same_type?(own_type(LibDuckDB.struct_type_child_type(left, i)), own_type(LibDuckDB.struct_type_child_type(right, i)))
      end
      true
    else
      true
    end
  end

  private def field_name(type, index)
    name = LibDuckDB.struct_type_child_name(type, index)
    begin
      String.new(name)
    ensure
      LibDuckDB.free(name)
    end
  end

  # Static scalar types win over values. Nilable types are unwrapped; a wider
  # union or a value-dependent wrapper is inferred from its first non-nil value.
  private def static_type(type : T.class) : LibDuckDB::LogicalType forall T
    {% if T.union? %}
      {% members = T.union_types.reject { |t| t == Nil } %}
      {% if members.size == 1 %}
        static_type({{members[0]}})
      {% else %}
        NULL_TYPE
      {% end %}
    {% elsif T == Bytes %}
      own_type(LibDuckDB.create_logical_type(LibDuckDB::Type::BLOB))
    {% elsif T < Array || T < Slice || T < StaticArray %}
      child = static_type({{T.type_vars[0]}})
      child.null? ? NULL_TYPE : own_type(LibDuckDB.create_list_type(child))
    {% elsif T < Hash %}
      key = static_type({{T.type_vars[0]}})
      value = static_type({{T.type_vars[1]}})
      key.null? || value.null? ? NULL_TYPE : own_type(LibDuckDB.create_map_type(key, value))
    {% else %}
      {% if T == Bool %}
        own_type(LibDuckDB.create_logical_type(LibDuckDB::Type::BOOLEAN))
      {% elsif T == Int8 %}
        own_type(LibDuckDB.create_logical_type(LibDuckDB::Type::TINYINT))
      {% elsif T == Int16 %}
        own_type(LibDuckDB.create_logical_type(LibDuckDB::Type::SMALLINT))
      {% elsif T == Int32 %}
        own_type(LibDuckDB.create_logical_type(LibDuckDB::Type::INTEGER))
      {% elsif T == Int64 %}
        own_type(LibDuckDB.create_logical_type(LibDuckDB::Type::BIGINT))
      {% elsif T == Int128 %}
        own_type(LibDuckDB.create_logical_type(LibDuckDB::Type::HUGEINT))
      {% elsif T == UInt8 %}
        own_type(LibDuckDB.create_logical_type(LibDuckDB::Type::UTINYINT))
      {% elsif T == UInt16 %}
        own_type(LibDuckDB.create_logical_type(LibDuckDB::Type::USMALLINT))
      {% elsif T == UInt32 %}
        own_type(LibDuckDB.create_logical_type(LibDuckDB::Type::UINTEGER))
      {% elsif T == UInt64 %}
        own_type(LibDuckDB.create_logical_type(LibDuckDB::Type::UBIGINT))
      {% elsif T == UInt128 %}
        own_type(LibDuckDB.create_logical_type(LibDuckDB::Type::UHUGEINT))
      {% elsif T == Float32 %}
        own_type(LibDuckDB.create_logical_type(LibDuckDB::Type::FLOAT))
      {% elsif T == Float64 %}
        own_type(LibDuckDB.create_logical_type(LibDuckDB::Type::DOUBLE))
      {% elsif T == String %}
        own_type(LibDuckDB.create_logical_type(LibDuckDB::Type::VARCHAR))
      {% elsif T == UUID %}
        own_type(LibDuckDB.create_logical_type(LibDuckDB::Type::UUID))
      {% elsif T == DuckDB::Date %}
        own_type(LibDuckDB.create_logical_type(LibDuckDB::Type::DATE))
      {% elsif T == DuckDB::Interval %}
        own_type(LibDuckDB.create_logical_type(LibDuckDB::Type::INTERVAL))
      {% elsif T == DuckDB::TimeTZ %}
        own_type(LibDuckDB.create_logical_type(LibDuckDB::Type::TIME_TZ))
      {% elsif T == DuckDB::BigNum %}
        own_type(LibDuckDB.create_logical_type(LibDuckDB::Type::BIGNUM))
      {% else %}
        NULL_TYPE
      {% end %}
    {% end %}
  end

  private def infer(values : Enumerable(T)) : LibDuckDB::LogicalType forall T
    infer(values, T)
  end

  private def infer(values, type : T.class) : LibDuckDB::LogicalType forall T
    logical = static_type(type)
    return logical unless logical.null?
    values.each do |value|
      return LibDuckDB.get_value_type(convert(value)) unless value.nil?
    end
    raise ConversionError.new("Cannot infer DuckDB child type from an empty or all-nil container; use a typed destination or concrete Crystal element type")
  end

  private def build_value(values : Array, destination) : LibDuckDB::Value
    build_list(values, destination)
  end

  private def build_value(values : Slice, destination) : LibDuckDB::Value
    build_list(values, destination)
  end

  private def build_value(values : StaticArray, destination) : LibDuckDB::Value
    build_list(values, destination)
  end

  private def build_value(value : Bytes, destination) : LibDuckDB::Value
    own(self.class.scalar(value))
  end

  private def build_list(values : Indexable(T), destination) : LibDuckDB::Value forall T
    id = type_id(destination)
    unless destination.null? || id.list? || id.array?
      raise ConversionError.new("Cannot build a list for DuckDB #{id}")
    end
    if id.array?
      size = LibDuckDB.array_type_array_size(destination)
      raise ConversionError.new("ARRAY requires #{size} elements, got #{values.size}") unless values.size == size
      child_type = own_type(LibDuckDB.array_type_child_type(destination))
    elsif id.list?
      child_type = own_type(LibDuckDB.list_type_child_type(destination))
    else
      child_type = infer(values, T)
    end
    child_type = infer(values, T) unless resolved?(child_type)
    children = values.map { |value| convert(value, child_type) }.to_a
    # DuckDB rejects a null values pointer even for a zero-element container.
    pointer = children.empty? ? pointerof(destination).as(LibDuckDB::Value*) : children.to_unsafe
    own(id.array? ? LibDuckDB.create_array_value(child_type, pointer, values.size.to_u64) : LibDuckDB.create_list_value(child_type, pointer, values.size.to_u64))
  end

  private def build_value(values : Hash, destination) : LibDuckDB::Value
    if type_id(destination).struct?
      values.each_key { |key| raise ConversionError.new("STRUCT requires String field names") unless key.is_a?(String) }
      return build_struct(values, destination)
    end
    unless destination.null? || type_id(destination).map?
      raise ConversionError.new("Cannot build a map for DuckDB #{type_id(destination)}")
    end
    values.each_key { |key| raise ConversionError.new("MAP keys cannot be NULL") if key.nil? }
    if destination.null?
      key_type = infer(values.each_key)
      value_type = infer(values.each_value)
      destination = own_type(LibDuckDB.create_map_type(key_type, value_type))
    else
      key_type = own_type(LibDuckDB.map_type_key_type(destination))
      value_type = own_type(LibDuckDB.map_type_value_type(destination))
    end
    key_type = infer(values.each_key) unless resolved?(key_type)
    value_type = infer(values.each_value) unless resolved?(value_type)
    keys = [] of LibDuckDB::Value
    children = [] of LibDuckDB::Value
    values.each do |key, value|
      keys << convert(key, key_type)
      children << convert(value, value_type)
    end
    key_pointer = keys.empty? ? pointerof(destination).as(LibDuckDB::Value*) : keys.to_unsafe
    value_pointer = children.empty? ? pointerof(destination).as(LibDuckDB::Value*) : children.to_unsafe
    own(LibDuckDB.create_map_value(destination, key_pointer, value_pointer, values.size.to_u64))
  end

  private def build_struct(values, destination) : LibDuckDB::Value
    count = LibDuckDB.struct_type_child_count(destination)
    raise ConversionError.new("STRUCT requires #{count} fields, got #{values.size}") unless values.size == count
    children = [] of LibDuckDB::Value
    count.times do |index|
      name = field_name(destination, index)
      raise ConversionError.new("STRUCT missing field '#{name}' (field names must match exactly)") unless values.has_key?(name)
      child_type = own_type(LibDuckDB.struct_type_child_type(destination, index))
      children << convert(values[name], child_type)
    end
    own(LibDuckDB.create_struct_value(destination, children.to_unsafe))
  end

  private def build_value(values : NamedTuple, destination) : LibDuckDB::Value
    if destination.null?
      names = [] of String
      children = [] of LibDuckDB::Value
      values.each do |name, value|
        field = name.to_s
        raise ConversionError.new("STRUCT field name contains a NUL byte") if field.includes?('\0')
        names << field
        children << convert(value)
      end
      types = children.map { |child| LibDuckDB.get_value_type(child) }
      pointers = names.map(&.to_unsafe)
      destination = own_type(LibDuckDB.create_struct_type(types.to_unsafe, pointers.to_unsafe, names.size.to_u64))
      own(LibDuckDB.create_struct_value(destination, children.to_unsafe))
    elsif type_id(destination).struct?
      build_struct(values.to_h.transform_keys(&.to_s), destination)
    else
      raise ConversionError.new("NamedTuple requires a STRUCT destination")
    end
  end

  private def build_value(value, destination) : LibDuckDB::Value
    if value.is_a?(Decimal)
      self.class.check_decimal(value, type_id(destination), type_id(destination).decimal? ? LibDuckDB.decimal_scale(destination) : 0_u8)
    elsif value.is_a?(Timestamp)
      self.class.check_precision(value.nanoseconds, type_id(destination), "Timestamp") unless value.infinite?
    elsif value.is_a?(TimeOfDay)
      self.class.check_precision(value.nanoseconds, type_id(destination), "TimeOfDay")
    end
    own(self.class.scalar(value))
  end

  def self.check_precision(nanos : Int, type : LibDuckDB::Type?, name : String)
    unit = case type
           when LibDuckDB::Type::TIMESTAMP_S                                                                               then 1_000_000_000
           when LibDuckDB::Type::TIMESTAMP_MS                                                                              then 1_000_000
           when LibDuckDB::Type::TIMESTAMP, LibDuckDB::Type::TIMESTAMP_TZ, LibDuckDB::Type::TIME, LibDuckDB::Type::TIME_TZ then 1000
           else                                                                                                                 1
           end
    raise ConversionError.new("Writing #{name} to #{type} would lose precision") unless nanos % unit == 0
  end

  def self.check_decimal(value : Decimal, type : LibDuckDB::Type?, scale : UInt8)
    scale = 0_u8 unless type == LibDuckDB::Type::DECIMAL
    case type
    when LibDuckDB::Type::FLOAT, LibDuckDB::Type::DOUBLE
      raise ConversionError.new("Write Decimal to a DECIMAL column to preserve exactness")
    when LibDuckDB::Type::DECIMAL, LibDuckDB::Type::TINYINT, LibDuckDB::Type::SMALLINT, LibDuckDB::Type::INTEGER, LibDuckDB::Type::BIGINT, LibDuckDB::Type::HUGEINT, LibDuckDB::Type::UTINYINT, LibDuckDB::Type::USMALLINT, LibDuckDB::Type::UINTEGER, LibDuckDB::Type::UBIGINT, LibDuckDB::Type::UHUGEINT, LibDuckDB::Type::BIGNUM, LibDuckDB::Type::BOOLEAN
      if value.scale > scale && value.value % (10_i128 ** (value.scale - scale)) != 0
        raise ConversionError.new("Writing DECIMAL would lose fractional digits")
      end
    end
  end

  def self.scalar(value : Nil) : LibDuckDB::Value
    LibDuckDB.create_null_value
  end

  def self.scalar(value : Bool) : LibDuckDB::Value
    LibDuckDB.create_bool(value ? 1_u8 : 0_u8)
  end

  {% for name in ["Int8", "Int16", "Int32", "Int64", "UInt8", "UInt16", "UInt32", "UInt64"] %}
    def self.scalar(value : {{name.id}}) : LibDuckDB::Value
      LibDuckDB.create_{{name.id.downcase}}(value)
    end
  {% end %}

  def self.scalar(value : Int128) : LibDuckDB::Value
    LibDuckDB.create_hugeint(HugeIntHelper.i128_to_huge(value))
  end

  def self.scalar(value : UInt128) : LibDuckDB::Value
    LibDuckDB.create_uhugeint(HugeIntHelper.u128_to_uhuge(value))
  end

  def self.scalar(value : Float32) : LibDuckDB::Value
    LibDuckDB.create_float(value)
  end

  def self.scalar(value : Float64) : LibDuckDB::Value
    LibDuckDB.create_double(value)
  end

  def self.scalar(value : String) : LibDuckDB::Value
    LibDuckDB.create_varchar_length(value, value.bytesize.to_u64)
  end

  def self.scalar(value : Bytes) : LibDuckDB::Value
    LibDuckDB.create_blob(value, value.size.to_u64)
  end

  {% for name in ["Date", "Interval", "Decimal", "TimeTZ"] %}
    def self.scalar(value : {{name.id}}) : LibDuckDB::Value
      LibDuckDB.{{ {"Date" => "create_date", "Interval" => "create_interval", "Decimal" => "create_decimal", "TimeTZ" => "create_time_tz_value"}[name].id }}(value)
    end
  {% end %}

  def self.scalar(value : UUID) : LibDuckDB::Value
    raw = value.bytes.reduce(0_u128) { |acc, byte| (acc << 8) | byte.to_u128 }
    LibDuckDB.create_uuid(HugeIntHelper.u128_to_uhuge(raw))
  end

  def self.scalar(value : BigNum) : LibDuckDB::Value
    bytes = value.bytes[3..]
    bytes.map! { |byte| ~byte } if value.negative?
    LibDuckDB.create_bignum(LibDuckDB::BigNum.new(data: bytes.to_unsafe, size: bytes.size.to_u64, is_negative: value.negative? ? 1_u8 : 0_u8))
  end

  def self.scalar(value : TimeOfDay) : LibDuckDB::Value
    value.nanoseconds % 1000 == 0 ? LibDuckDB.create_time(value) : LibDuckDB.create_time_ns(LibDuckDB::TimeNS.new(nanos: value.nanoseconds))
  end

  def self.scalar(value : Time) : LibDuckDB::Value
    scalar(Timestamp.new(value))
  end

  def self.scalar(value : Timestamp) : LibDuckDB::Value
    nanos = value.nanoseconds
    if value.infinite? || (nanos % 1000 == 0 && -Int64::MAX < nanos // 1000 < Int64::MAX)
      value.timezone? ? LibDuckDB.create_timestamp_tz(value.to_unsafe) : LibDuckDB.create_timestamp(value.to_unsafe)
    elsif value.timezone?
      raise ConversionError.new("Timestamp is outside DuckDB's nanosecond TIMESTAMP_TZ range") unless -Int64::MAX < nanos < Int64::MAX
      TimestampTZNS.create(nanos.to_i64)
    elsif -Int64::MAX < nanos < Int64::MAX
      LibDuckDB.create_timestamp_ns(LibDuckDB::TimestampNS.new(nanos: nanos.to_i64))
    elsif nanos % 1_000_000 == 0 && -Int64::MAX < nanos // 1_000_000 < Int64::MAX
      LibDuckDB.create_timestamp_ms(LibDuckDB::TimestampMS.new(millis: (nanos // 1_000_000).to_i64))
    elsif nanos % 1_000_000_000 == 0 && -Int64::MAX < nanos // 1_000_000_000 < Int64::MAX
      LibDuckDB.create_timestamp_s(LibDuckDB::TimestampS.new(seconds: (nanos // 1_000_000_000).to_i64))
    else
      raise ConversionError.new("Timestamp is outside DuckDB's range or cannot be written exactly")
    end
  end

  def self.scalar(value) : LibDuckDB::Value
    raise ConversionError.new("Unsupported DuckDB nested leaf #{value.class}")
  end
end
