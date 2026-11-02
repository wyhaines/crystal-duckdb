class DuckDB::Appender
  # Literal table name, without SQL quoting or schema qualification.
  getter table_name : String
  # Whether the native appender has been closed.
  getter? closed = false
  @types = [] of LibDuckDB::Type
  @scales = [] of UInt8
  @column_index = 0
  @columns = [] of AppendColumn
  @chunk = Pointer(Void).null.as(LibDuckDB::DataChunk)
  @capacity = 0
  # Complete direct rows occupy [0, @row_count); a direct partial row follows.
  @row_count = 0
  # Ended rows still in DuckDB's native row buffer, modulo vector_size.
  # Never submit a data chunk while this is nonzero: DuckDB reorders it.
  @native_pending = 0
  @native_row = false

  # Opens a literal table name in the optional schema and catalog, owning one
  # writable data chunk whose exact column types come from the native appender.
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
      logical_types = [] of LibDuckDB::LogicalType
      begin
        LibDuckDB.appender_column_count(self).times do |index|
          logical = LibDuckDB.appender_column_type(self, index)
          raise Exception.new("Could not get appender column type") if logical.null?
          logical_types << logical
          column = AppendColumn.new(logical)
          @columns << column
          @types << column.type
          @scales << column.scale
        end
        @chunk = LibDuckDB.create_data_chunk(logical_types.to_unsafe, logical_types.size)
        raise Exception.new("Could not create appender data chunk") if @chunk.null?
        @capacity = LibDuckDB.vector_size.to_i32
        bind_columns
      ensure
        logical_types.each { |logical| LibDuckDB.destroy_logical_type(pointerof(logical)) }
      end
      @connection.register_appender(self)
    rescue ex
      LibDuckDB.destroy_data_chunk(pointerof(@chunk)) unless @chunk.null?
      LibDuckDB.appender_destroy(pointerof(@appender))
      raise ex
    end
  end

  # Appends one value to the current row; raises on conversion failure.
  def <<(value : Nil)
    append(value) { LibDuckDB.append_null(self) }
    self
  end

  # Appends one value to the current row; raises on conversion failure.
  def <<(value : Bool)
    append(value) { LibDuckDB.append_bool(self, value ? 1_u8 : 0_u8) }
    self
  end

  # Begins a row. Like DuckDB's native begin_row, this does not clear a partial row.
  def begin_row
    to_unsafe
    nil
  end

  # Ends a complete row; short rows raise and can be completed and retried.
  # Full chunks are handed to DuckDB, which may report constraints at this point.
  def end_row
    to_unsafe
    if @native_row || @column_index != @columns.size
      start_native_row
      state = LibDuckDB.appender_end_row(self)
      # A full EndRow can fail after draining the native buffer (constraints).
      # A short EndRow fails before incrementing its row count.
      if state.success? || @column_index == @columns.size
        @native_pending = (@native_pending + 1) % @capacity
      end
      native_check(state, "end_row")
      @native_row = false
    else
      @row_count += 1
    end
    @column_index = 0
    drain_chunk if @row_count + @native_pending == @capacity
    nil
  end

  # Persists completed rows. An unfinished row raises and follows DuckDB's
  # native recovery/discard behavior; it is never silently completed.
  def flush
    to_unsafe
    if @column_index > 0 || @native_row
      start_native_row
    else
      drain_chunk
    end
    state = LibDuckDB.appender_flush(self)
    # With a complete row, FlushChunk drains the native row buffer before a
    # possible constraint/UTF-8 failure. An incomplete Flush leaves it intact.
    @native_pending = 0 if @column_index == 0
    native_check(state, "flush")
    nil
  end

  # Flushes pending rows and destroys the handle, including when flushing fails.
  def close
    return if @closed
    begin
      if @column_index > 0 || @native_row
        start_native_row
      else
        drain_chunk
      end
      unless LibDuckDB.appender_close(self).success?
        raise Exception.new("Failed to close for table '#{@table_name}'")
      end
    ensure
      LibDuckDB.destroy_data_chunk(pointerof(@chunk)) unless @chunk.null?
      LibDuckDB.appender_destroy(pointerof(@appender))
      @closed = true
      @connection.unregister_appender(self)
    end
  end

  {% for name in ["Int8", "Int16", "Int32", "Int64", "UInt8", "UInt16", "UInt32", "UInt64"] %}
    # Appends one integer to the current row.
    def <<(value : {{name.id}})
      append(value) { LibDuckDB.append_{{name.id.downcase}}(self, value) }
      self
    end
  {% end %}

  # Appends one value to the current row; raises on conversion failure.
  def <<(value : Int128)
    append(value) { LibDuckDB.append_hugeint(self, HugeIntHelper.i128_to_huge(value)) }
    self
  end

  # Appends one value to the current row; raises on conversion failure.
  def <<(value : Float32)
    append(value) { LibDuckDB.append_float(self, value) }
    self
  end

  # Appends one value to the current row; raises on conversion failure.
  def <<(value : Float64)
    append(value) { LibDuckDB.append_double(self, value) }
    self
  end

  # Appends one value to the current row; raises on conversion failure.
  def <<(value : String)
    append(value) { LibDuckDB.append_varchar_length(self, value, value.bytesize) }
    self
  end

  # Appends one value to the current row; raises on conversion failure.
  def <<(value : Date)
    append(value) { LibDuckDB.append_date(self, value) }
    self
  end

  # Appends one value to the current row; raises on conversion failure.
  def <<(value : TimeOfDay)
    check_precision(value.nanoseconds, time: true)
    return self if append_direct(value)
    if value.nanoseconds % 1000 == 0
      append(value) { LibDuckDB.append_time(self, value) }
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
    return self if append_direct(value)
    if value.infinite? || (value.nanoseconds % 1000 == 0 && -Int64::MAX < value.nanoseconds // 1000 < Int64::MAX)
      if value.timezone?
        append_owned_value(LibDuckDB.create_timestamp_tz(value.to_unsafe))
      else
        append(value) { LibDuckDB.append_timestamp(self, value) }
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
    append(value) { LibDuckDB.append_interval(self, value) }
    self
  end

  # Appends one value to the current row; raises on conversion failure.
  def <<(value : Bytes)
    append(value) { LibDuckDB.append_blob(self, value, value.size) }
    self
  end

  # Appends a UTC Time, letting DuckDB cast to the destination precision.
  # DuckDB may reject casts unsupported by its native appender.
  def <<(value : Time)
    append_timestamp(Timestamp.new(value))
  end

  # Appends an unsigned 128-bit integer without a floating-point conversion.
  def <<(value : UInt128)
    append(value) { LibDuckDB.append_uhugeint(self, HugeIntHelper.u128_to_uhuge(value)) }
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
    return self if append_direct(value)
    append_owned_value(LibDuckDB.create_decimal(value))
  end

  # Appends a UUID with all 128 bits preserved.
  def <<(value : UUID)
    return self if append_direct(value)
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

  # Appends one Indexable per destination column, with equal lengths and nil
  # elements for NULL. Element types must match the direct-write families
  # (including lossless integer widening); casts are available through #<<.
  # Counts, lengths and element types are checked before any rows are appended.
  # Values must fit exactly. A bad value discards its whole input chunk; earlier
  # chunks remain buffered. Call only between rows. Inputs are copied, not retained.
  def append_columns(*columns : *T) : Nil forall T
    to_unsafe
    if @column_index > 0 || @native_row
      raise Exception.new("append_columns requires a row boundary")
    end
    unless columns.size == @columns.size
      raise Exception.new("Expected #{@columns.size} columns, got #{columns.size}")
    end
    {% if T.size > 0 %}
      {% for column_type in T %}
        {% unless column_type < Indexable %}
          {% raise "append_columns requires one Indexable per destination column" %}
        {% end %}
      {% end %}
      length = columns[0].size
      {% for column_type, index in T %}
        column = columns[{{index}}]
        raise Exception.new("Column lengths must match") unless column.size == length
        unless @columns[{{index}}].accepts?(column)
          raise Exception.new("Column {{index}} element type does not match #{@columns[{{index}}].type}")
        end
      {% end %}
      offset = 0
      while offset < length
        count = Math.min(@capacity - @row_count - @native_pending, length - offset)
        {% for column_type, index in T %}
          column = columns[{{index}}]
          writer = @columns[{{index}}]
          count.times do |row|
            unless writer.write(column[offset + row], @row_count + row)
              raise Exception.new("Column {{index}} value at row #{offset + row} cannot be appended exactly to #{writer.type}")
            end
          end
        {% end %}
        @row_count += count
        offset += count
        drain_chunk if @row_count + @native_pending == @capacity
      end
    {% end %}
  end

  # Yields one row, ending it after the block returns normally.
  # On a block exception, close retains DuckDB's partial-row discard behavior.
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
      start_native_row
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

  # Try the exact destination write before invoking a native converter.
  @[AlwaysInline]
  private def append(value, & : -> LibDuckDB::State)
    return if append_direct(value)
    start_native_row
    check yield, value
  end

  @[AlwaysInline]
  private def append_direct(value) : Bool
    to_unsafe
    return false if @native_row || @column_index >= @columns.size
    return false unless @columns[@column_index].write(value, @row_count)
    @column_index += 1
    true
  end

  private def bind_columns
    @columns.each_with_index do |column, index|
      column.bind(LibDuckDB.data_chunk_get_vector(@chunk, index))
    end
  end

  private def reset_chunk
    LibDuckDB.data_chunk_reset(@chunk)
    @row_count = 0
    bind_columns
  end

  private def drain_chunk(reset : Bool = true, *, native : Bool = false)
    if @row_count > 0
      if @native_pending == 0 && !native
        LibDuckDB.data_chunk_set_size(@chunk, @row_count)
        state = LibDuckDB.append_data_chunk(self, @chunk)
        # The chunk was consumed even when the ensuing automatic flush failed.
        # Never submit it again on close (2.0 discards the failed collection).
        @row_count = 0
        native_check(state, "append data chunk")
      else
        # append_data_chunk does NOT flush native rows first (both engines).
        # Fill the remaining native buffer in order. Once it reaches vector_size
        # EndRow drains it, and subsequent chunks can use append_data_chunk again.
        @row_count.times do |row|
          @columns.each { |column| native_check(column.replay(@appender, row), "replay value") }
          state = LibDuckDB.appender_end_row(self)
          @native_pending = (@native_pending + 1) % @capacity
          native_check(state, "end_row")
        end
      end
    end
    reset_chunk if reset
  rescue ex
    # A flush error must not replay completed local rows on a later close.
    reset_chunk
    raise ex
  end

  private def start_native_row
    to_unsafe
    return if @native_row
    # Replay the partial chunk as well as the current prefix. Submitting a short
    # chunk here would shift DuckDB's automatic flush/discard boundaries.
    drain_chunk(reset: false, native: true)
    @column_index.times do |index|
      native_check(@columns[index].replay(@appender, @row_count), "replay value")
    end
    @native_row = true
    reset_chunk
  end

  private def native_check(state : LibDuckDB::State, operation : String)
    unless state.success?
      error = LibDuckDB.appender_error(self)
      detail = error.null? ? "" : ": #{String.new(error)}"
      raise Exception.new("Failed to #{operation} for table '#{@table_name}'#{detail}")
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
