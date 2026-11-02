class DuckDB::Appender
  # Literal table name, without SQL quoting or schema qualification.
  getter table_name : String
  # Whether the native appender has been closed.
  getter? closed = false
  @types = [] of LibDuckDB::Type
  @scales = [] of UInt8
  @column_index = 0

  # Opens a literal table name in the optional schema and catalog.
  # Identifiers containing NUL bytes raise DuckDB::Exception.
  def initialize(@connection : Connection, @table_name : String, schema : String? = nil, catalog : String? = nil)
    @connection.check_query_allowed
    [@table_name, schema, catalog].each do |name|
      raise Exception.new("Appender identifier contains a NUL byte") if name.try(&.includes?('\0'))
    end
    state = LibDuckDB.appender_create_ext(@connection, catalog, schema, @table_name, out @appender)
    begin
      unless state.success?
        raise Exception.new("Failed to create appender for table '#{@table_name}'")
      end
      LibDuckDB.appender_column_count(self).times do |index|
        logical = LibDuckDB.appender_column_type(self, index)
        begin
          type = LibDuckDB.get_type_id(logical)
          @types << type
          @scales << (type.decimal? ? LibDuckDB.decimal_scale(logical) : 0_u8)
        ensure
          LibDuckDB.destroy_logical_type(pointerof(logical))
        end
      end
      @connection.register_appender(self)
    rescue ex
      LibDuckDB.appender_destroy(pointerof(@appender))
      raise ex
    end
  end

  # Appends one value to the current row; raises on conversion failure.
  def <<(value : Nil)
    check LibDuckDB.append_null(self), value
    self
  end

  # Appends one value to the current row; raises on conversion failure.
  def <<(value : Bool)
    check LibDuckDB.append_bool(self, value ? 1_u8 : 0_u8), value
    self
  end

  {% for name in ["begin_row", "end_row", "flush"] %}
    # Calls the appender row or flush operation; raises on failure.
    def {{name.id}}
      unless LibDuckDB.appender_{{name.id}}(self).success?
        raise Exception.new("Failed to {{name.id}} for table '#{@table_name}'")
      end
      {% if name == "end_row" %}
        @column_index = 0
        nil
      {% end %}
    end
  {% end %}

  # Flushes pending rows and destroys the handle, including when flushing fails.
  def close
    return if @closed
    begin
      unless LibDuckDB.appender_close(self).success?
        raise Exception.new("Failed to close for table '#{@table_name}'")
      end
    ensure
      LibDuckDB.appender_destroy(pointerof(@appender))
      @closed = true
      @connection.unregister_appender(self)
    end
  end

  {% for name in ["Int8", "Int16", "Int32", "Int64", "UInt8", "UInt16", "UInt32", "UInt64"] %}
    # Appends one integer to the current row.
    def <<(value : {{name.id}})
      check LibDuckDB.append_{{name.id.downcase}}(self, value), value
      self
    end
  {% end %}

  # Appends one value to the current row; raises on conversion failure.
  def <<(value : Int128)
    check LibDuckDB.append_hugeint(self, HugeIntHelper.i128_to_huge(value)), value
    self
  end

  # Appends one value to the current row; raises on conversion failure.
  def <<(value : Float32)
    check LibDuckDB.append_float(self, value), value
    self
  end

  # Appends one value to the current row; raises on conversion failure.
  def <<(value : Float64)
    check LibDuckDB.append_double(self, value), value
    self
  end

  # Appends one value to the current row; raises on conversion failure.
  def <<(value : String)
    check LibDuckDB.append_varchar_length(self, value, value.bytesize), value
    self
  end

  # Appends one value to the current row; raises on conversion failure.
  def <<(value : Date)
    check LibDuckDB.append_date(self, value), value
    self
  end

  # Appends one value to the current row; raises on conversion failure.
  def <<(value : TimeOfDay)
    check_precision(value.nanoseconds, time: true)
    if value.nanoseconds % 1000 == 0
      check LibDuckDB.append_time(self, value), value
    else
      append_owned_value(LibDuckDB.create_time_ns(LibDuckDB::TimeNS.new(nanos: value.nanoseconds)))
    end
    self
  end

  # Appends one value to the current row; raises on conversion failure.
  def <<(value : Timestamp)
    check_precision(value.nanoseconds) unless value.infinite?
    append_timestamp(value)
  end

  private def append_timestamp(value : Timestamp)
    if value.infinite? || (value.nanoseconds % 1000 == 0 && -Int64::MAX < value.nanoseconds // 1000 < Int64::MAX)
      if value.timezone?
        append_owned_value(LibDuckDB.create_timestamp_tz(value.to_unsafe))
      else
        check LibDuckDB.append_timestamp(self, value), value
      end
    else
      nanos = value.nanoseconds
      if value.timezone?
        raise Exception.new("Nanosecond TIMESTAMP_TZ appending is unavailable in the DuckDB 1.5.6 v1 C API")
      elsif -Int64::MAX < nanos < Int64::MAX
        append_owned_value(LibDuckDB.create_timestamp_ns(LibDuckDB::TimestampNS.new(nanos: nanos.to_i64)))
      elsif nanos % 1_000_000 == 0 && -Int64::MAX < nanos // 1_000_000 < Int64::MAX
        append_owned_value(LibDuckDB.create_timestamp_ms(LibDuckDB::TimestampMS.new(millis: (nanos // 1_000_000).to_i64)))
      elsif nanos % 1_000_000_000 == 0 && -Int64::MAX < nanos // 1_000_000_000 < Int64::MAX
        append_owned_value(LibDuckDB.create_timestamp_s(LibDuckDB::TimestampS.new(seconds: (nanos // 1_000_000_000).to_i64)))
      else
        raise Exception.new("Timestamp is outside DuckDB's range or cannot be appended exactly")
      end
    end
    self
  end

  # Appends one value to the current row; raises on conversion failure.
  def <<(value : Interval)
    check LibDuckDB.append_interval(self, value), value
    self
  end

  # Appends one value to the current row; raises on conversion failure.
  def <<(value : Bytes)
    check LibDuckDB.append_blob(self, value, value.size), value
    self
  end

  # Appends a UTC Time, letting DuckDB cast to the destination precision.
  # DuckDB may reject casts unsupported by its native appender.
  def <<(value : Time)
    append_timestamp(Timestamp.new(value))
  end

  # Appends an unsigned 128-bit integer without a floating-point conversion.
  def <<(value : UInt128)
    check LibDuckDB.append_uhugeint(self, HugeIntHelper.u128_to_uhuge(value)), value
    self
  end

  # Appends an exact DECIMAL; reducing scale requires trailing zero digits.
  def <<(value : Decimal)
    to_unsafe
    if @types[@column_index]?.try(&.decimal?)
      scale = @scales[@column_index]
      if value.scale > scale && value.value % (10_i128 ** (value.scale - scale)) != 0
        raise Exception.new("Appending DECIMAL would lose fractional digits")
      end
    elsif type = @types[@column_index]?
      case type
      when .float?, .double?
        raise Exception.new("Append Decimal to a DECIMAL column to preserve exactness")
      when .tinyint?, .smallint?, .integer?, .bigint?, .hugeint?, .utinyint?, .usmallint?, .uinteger?, .ubigint?, .uhugeint?, .bignum?, .boolean?
        if value.value % (10_i128 ** value.scale) != 0
          raise Exception.new("Appending DECIMAL would lose fractional digits")
        end
      end
    end
    append_owned_value(LibDuckDB.create_decimal(value))
  end

  # Appends a UUID with all 128 bits preserved.
  def <<(value : UUID)
    raw = value.bytes.reduce(0_u128) { |acc, byte| (acc << 8) | byte.to_u128 }
    append_owned_value(LibDuckDB.create_uuid(HugeIntHelper.u128_to_uhuge(raw)))
  end

  # Appends an arbitrary precision integer from its exact magnitude bytes.
  def <<(value : BigNum)
    bytes = value.bytes[3..]
    bytes.map! { |byte| ~byte } if value.negative?
    native = LibDuckDB::BigNum.new(data: bytes.to_unsafe, size: bytes.size.to_u64, is_negative: value.negative? ? 1_u8 : 0_u8)
    append_owned_value(LibDuckDB.create_bignum(native))
  end

  # Appends a local time with its UTC offset, at microsecond precision.
  def <<(value : TimeTZ)
    append_owned_value(LibDuckDB.create_time_tz_value(value))
  end

  # Yields one row, ending it after the block returns normally.
  def row(&block)
    begin_row
    yield self
    end_row
  end

  # :nodoc:
  def to_unsafe
    raise Exception.new("Appender is closed") if @closed
    @appender
  end

  private def append_owned_value(value : LibDuckDB::Value)
    raise Exception.new("Could not create DuckDB appender value") if value.null?
    begin
      check LibDuckDB.append_value(self, value), "DuckDB value"
    ensure
      LibDuckDB.destroy_value(pointerof(value))
    end
    self
  end

  private def check_precision(nanos : Int, *, time : Bool = false)
    to_unsafe
    type = @types[@column_index]?
    unit = case type
           when LibDuckDB::Type::TIMESTAMP_S then 1_000_000_000
           when LibDuckDB::Type::TIMESTAMP_MS then 1_000_000
           when LibDuckDB::Type::TIMESTAMP, LibDuckDB::Type::TIMESTAMP_TZ, LibDuckDB::Type::TIME, LibDuckDB::Type::TIME_TZ then 1000
           else 1
           end
    if nanos % unit != 0
      raise Exception.new("Appending #{time ? "TimeOfDay" : "Timestamp"} to #{type} would lose precision")
    end
  end

  private def check(state, value)
    unless state.success?
      error = LibDuckDB.appender_error(self)
      detail = error.null? ? "" : ": #{String.new(error)}"
      raise Exception.new("Failed to append value '#{value}' for table '#{@table_name}'#{detail}")
    end
    @column_index += 1
  end
end
