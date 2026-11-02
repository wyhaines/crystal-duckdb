# :nodoc:
# An appender-owned vector. No writable pointers escape the appender.
class DuckDB::AppendColumn
  getter type : LibDuckDB::Type
  getter scale = 0_u8
  @width = 0_u8
  @storage = LibDuckDB::Type::INVALID
  @limit = 0_i128
  @vector = Pointer(Void).null.as(LibDuckDB::Vector)
  @data = Pointer(Void).null
  @validity = Pointer(UInt64).null

  def initialize(logical : LibDuckDB::LogicalType)
    @type = LibDuckDB.get_type_id(logical)
    if @type.decimal?
      @scale = LibDuckDB.decimal_scale(logical)
      @width = LibDuckDB.decimal_width(logical)
      @storage = LibDuckDB.decimal_internal_type(logical)
      @limit = 10_i128 ** @width
    end
  end

  def bind(@vector : LibDuckDB::Vector)
    LibDuckDB.vector_ensure_validity_writable(@vector)
    @data = LibDuckDB.vector_get_data(@vector)
    @validity = LibDuckDB.vector_get_validity(@vector)
  end

  # Columnar loading deliberately accepts only exact destination families.
  def accepts?(column : Indexable(T)) : Bool forall T
    {% for member in T.union_types %}
      {% if member == Nil %}
      {% elsif member < Int %}
        case @type
        {% for target_info in { {Int8, :TINYINT}, {Int16, :SMALLINT}, {Int32, :INTEGER}, {Int64, :BIGINT}, {Int128, :HUGEINT}, {UInt8, :UTINYINT}, {UInt16, :USMALLINT}, {UInt32, :UINTEGER}, {UInt64, :UBIGINT}, {UInt128, :UHUGEINT} } %}
        {% target = target_info[0] %}
        {% kind = target_info[1] %}
          {% signed = member.stringify.starts_with?("Int") %}
          {% sign = target.stringify.starts_with?("Int") %}
          {% if (signed == sign && target.stringify.gsub(/[^0-9]/, "").to_i >= member.stringify.gsub(/[^0-9]/, "").to_i) || (!signed && sign && target.stringify.gsub(/[^0-9]/, "").to_i > member.stringify.gsub(/[^0-9]/, "").to_i) %}
            when LibDuckDB::Type::{{kind.id}}
          {% end %}
        {% end %}
        else return false
        end
      {% elsif member == Timestamp || member == ::Time %}
        return false unless @type.timestamp? || @type.timestamp_s? || @type.timestamp_ms? || @type.timestamp_ns? || @type.timestamp_tz? || @type.timestamp_tz_ns?
      {% elsif member == TimeOfDay %}
        return false unless @type.time? || @type.time_ns?
      {% else %}
        {% kinds = {Bool => "BOOLEAN", Float32 => "FLOAT", Float64 => "DOUBLE", String => "VARCHAR", Bytes => "BLOB", Decimal => "DECIMAL", UUID => "UUID", Date => "DATE", Interval => "INTERVAL"} %}
        {% if kind = kinds[member] %}
          return false unless @type == LibDuckDB::Type::{{kind.id}}
        {% else %}
          return false
        {% end %}
      {% end %}
    {% end %}
    true
  end

  def null?(row : Int32) : Bool
    (@validity[row // 64] & (1_u64 << (row % 64))) == 0
  end

  @[AlwaysInline]
  def write(value : Nil, row : Int32) : Bool
    @validity[row // 64] &= ~(1_u64 << (row % 64))
    true
  end

  {% for source_info in { {Int8, 8, true}, {Int16, 16, true}, {Int32, 32, true}, {Int64, 64, true}, {Int128, 128, true}, {UInt8, 8, false}, {UInt16, 16, false}, {UInt32, 32, false}, {UInt64, 64, false}, {UInt128, 128, false} } %}

  {% source = source_info[0] %}

  {% bits = source_info[1] %}

  {% signed = source_info[2] %}
    @[AlwaysInline]
    def write(value : {{source}}, row : Int32) : Bool
      case @type
      {% for target_info in { {Int8, :TINYINT, 8, true}, {Int16, :SMALLINT, 16, true}, {Int32, :INTEGER, 32, true}, {Int64, :BIGINT, 64, true}, {Int128, :HUGEINT, 128, true}, {UInt8, :UTINYINT, 8, false}, {UInt16, :USMALLINT, 16, false}, {UInt32, :UINTEGER, 32, false}, {UInt64, :UBIGINT, 64, false}, {UInt128, :UHUGEINT, 128, false} } %}
      {% target = target_info[0] %}
      {% kind = target_info[1] %}
      {% size = target_info[2] %}
      {% sign = target_info[3] %}
        {% if (signed == sign && size >= bits) || (!signed && sign && size > bits) %}
          when LibDuckDB::Type::{{kind.id}}
            {% if target == Int128 %}
              put(row, HugeIntHelper.i128_to_huge(value.to_i128))
            {% elsif target == UInt128 %}
              put(row, HugeIntHelper.u128_to_uhuge(value.to_u128))
            {% else %}
              put(row, {{target}}.new(value))
            {% end %}
        {% end %}
      {% end %}
      else return false
      end
      true
    end
  {% end %}

  {% for source_info in { {Bool, :BOOLEAN, UInt8}, {Float32, :FLOAT, Float32}, {Float64, :DOUBLE, Float64}, {Date, :DATE, LibDuckDB::Date}, {Interval, :INTERVAL, LibDuckDB::Interval} } %}

  {% source = source_info[0] %}

  {% kind = source_info[1] %}

  {% native = source_info[2] %}
    @[AlwaysInline]
    def write(value : {{source}}, row : Int32) : Bool
      return false unless @type == LibDuckDB::Type::{{kind.id}}
      {% if source == Bool %}
        put(row, value ? 1_u8 : 0_u8)
      {% elsif source == Date || source == Interval %}
        put(row, value.to_unsafe)
      {% else %}
        put(row, value)
      {% end %}
      true
    end
  {% end %}

  def write(value : String, row : Int32) : Bool
    return false unless @type.varchar?
    @validity[row // 64] |= 1_u64 << (row % 64)
    LibDuckDB.vector_assign_string_element_len(@vector, row, value, value.bytesize)
    # The C API silently writes NULL on invalid UTF-8. Replay through the native
    # row appender instead, preserving its deferred error and discard behavior.
    !null?(row)
  end

  def write(value : Bytes, row : Int32) : Bool
    return false unless @type.blob?
    @validity[row // 64] |= 1_u64 << (row % 64)
    LibDuckDB.vector_assign_string_element_len(@vector, row, value.to_unsafe.as(LibC::Char*), value.size)
    true
  end

  def write(value : Decimal, row : Int32) : Bool
    return false unless @type.decimal?
    raw = value.value
    if value.scale < @scale
      factor = 10_i128 ** (@scale - value.scale)
      return false if raw.abs > (@limit - 1) // factor
      raw *= factor
    elsif value.scale > @scale
      factor = 10_i128 ** (value.scale - @scale)
      return false unless raw % factor == 0
      raw //= factor
    end
    return false unless -@limit < raw < @limit
    case @storage
    when .smallint? then put(row, raw.to_i16)
    when .integer?  then put(row, raw.to_i32)
    when .bigint?   then put(row, raw.to_i64)
    else                 put(row, HugeIntHelper.i128_to_huge(raw))
    end
    true
  end

  def write(value : UUID, row : Int32) : Bool
    return false unless @type.uuid?
    raw = value.bytes.reduce(0_u128) { |acc, byte| (acc << 8) | byte.to_u128 }
    put(row, HugeIntHelper.i128_to_huge((raw ^ (1_u128 << 127)).to_i128!))
    true
  end

  def write(value : TimeOfDay, row : Int32) : Bool
    case @type
    when .time?
      return false unless value.nanoseconds % 1000 == 0
      put(row, value.nanoseconds // 1000)
    when .time_ns?
      put(row, value.nanoseconds)
    else return false
    end
    true
  end

  def write(value : Timestamp, row : Int32) : Bool
    unit = case @type
           when .timestamp?       then 1000_i64
           when .timestamp_s?     then 1_000_000_000_i64
           when .timestamp_ms?    then 1_000_000_i64
           when .timestamp_ns?    then 1_i64
           when .timestamp_tz?    then 1000_i64
           when .timestamp_tz_ns? then 1_i64
           else                        return false
           end
    # Crossing TZ provenance can invoke the connection's time zone cast.
    return false unless value.timezone? == (@type.timestamp_tz? || @type.timestamp_tz_ns?)
    if value.infinite?
      put(row, value.infinity > 0 ? Int64::MAX : -Int64::MAX)
    else
      return false unless value.nanoseconds % unit == 0
      raw = value.nanoseconds // unit
      return false unless -Int64::MAX < raw < Int64::MAX
      put(row, raw.to_i64)
    end
    true
  end

  def write(value : ::Time, row : Int32) : Bool
    write(Timestamp.new(value), row)
  end

  def write(value, row : Int32) : Bool
    false
  end

  # Replay only already-exact destination values. This is used when a native
  # row buffer precedes a chunk, or a fallback occurs after a direct row prefix.
  def replay(appender : LibDuckDB::Appender, row : Int32) : LibDuckDB::State
    return LibDuckDB.append_null(appender) if null?(row)
    {% begin %}
    case @type
    {% for kind_info in { {:BOOLEAN, UInt8, :append_bool}, {:TINYINT, Int8, :append_int8}, {:SMALLINT, Int16, :append_int16}, {:INTEGER, Int32, :append_int32}, {:BIGINT, Int64, :append_int64}, {:HUGEINT, LibDuckDB::HugeInt, :append_hugeint}, {:UTINYINT, UInt8, :append_uint8}, {:USMALLINT, UInt16, :append_uint16}, {:UINTEGER, UInt32, :append_uint32}, {:UBIGINT, UInt64, :append_uint64}, {:UHUGEINT, LibDuckDB::UHugeInt, :append_uhugeint}, {:FLOAT, Float32, :append_float}, {:DOUBLE, Float64, :append_double}, {:DATE, LibDuckDB::Date, :append_date}, {:TIME, LibDuckDB::Time, :append_time}, {:TIMESTAMP, LibDuckDB::Timestamp, :append_timestamp}, {:INTERVAL, LibDuckDB::Interval, :append_interval} } %}
    {% kind = kind_info[0] %}
    {% native = kind_info[1] %}
    {% method = kind_info[2] %}
      when LibDuckDB::Type::{{kind.id}}
        LibDuckDB.{{method.id}}(appender, DuckDB.c_arg(get(row, {{native}})))
    {% end %}
    when .varchar?, .blob?
      ptr, length = VectorView.new(@vector).string_data(row.to_i64)
      @type.varchar? ? LibDuckDB.append_varchar_length(appender, ptr.as(LibC::Char*), length) : LibDuckDB.append_blob(appender, ptr, length)
    when .decimal?
      raw = case @storage
            when .smallint? then get(row, Int16).to_i128
            when .integer? then get(row, Int32).to_i128
            when .bigint? then get(row, Int64).to_i128
            else HugeIntHelper.huge_to_i128(get(row, LibDuckDB::HugeInt))
            end
      append_owned(appender, LibDuckDB.create_decimal(Decimal.new(raw, @width, @scale)))
    when .uuid?
      raw = HugeIntHelper.huge_to_i128(get(row, LibDuckDB::HugeInt)).to_u128! ^ (1_u128 << 127)
      append_owned(appender, LibDuckDB.create_uuid(HugeIntHelper.u128_to_uhuge(raw)))
    when .time_ns?
      append_owned(appender, LibDuckDB.create_time_ns(LibDuckDB::TimeNS.new(nanos: get(row, Int64))))
    when .timestamp_s?
      append_owned(appender, LibDuckDB.create_timestamp_s(LibDuckDB::TimestampS.new(seconds: get(row, Int64))))
    when .timestamp_ms?
      append_owned(appender, LibDuckDB.create_timestamp_ms(LibDuckDB::TimestampMS.new(millis: get(row, Int64))))
    when .timestamp_ns?
      append_owned(appender, LibDuckDB.create_timestamp_ns(LibDuckDB::TimestampNS.new(nanos: get(row, Int64))))
    when .timestamp_tz?
      append_owned(appender, LibDuckDB.create_timestamp_tz(LibDuckDB::Timestamp.new(micros: get(row, Int64))))
    when .timestamp_tz_ns?
      # The 2.0-only value constructor cannot be linked on 1.5.6. UTC text is
      # exact even with a non-UTC session zone, including BC dates/infinities.
      text = Timestamp.from_raw(get(row, Int64), @type).to_s
      LibDuckDB.append_varchar_length(appender, text, text.bytesize)
    else
      raise Exception.new("Cannot replay a direct #{@type} value")
    end
    {% end %}
  end

  private def append_owned(appender, value : LibDuckDB::Value) : LibDuckDB::State
    raise Exception.new("Could not create DuckDB appender value") if value.null?
    begin
      LibDuckDB.append_value(appender, value)
    ensure
      LibDuckDB.destroy_value(pointerof(value))
    end
  end

  @[AlwaysInline]
  private def put(row, value : T) forall T
    @validity[row // 64] |= 1_u64 << (row % 64)
    @data.as(T*)[row] = value
  end

  private def get(row, type : T.class) : T forall T
    @data.as(T*)[row]
  end
end
