class DuckDB::Statement < DB::Statement
  def initialize(connection, command)
    super(connection, command)
    raise Exception.new("SQL text contains a NUL byte") if command.includes?('\0')
    @connection.as(Connection).check_query_allowed
    state = LibDuckDB.prepare(duckdb_connection, command, out @statement)
    unless state.success?
      begin
        check state
      ensure
        LibDuckDB.destroy_prepare(pointerof(@statement))
      end
    end
  end

  @active_results = Set(ResultSet).new
  @closing = false

  protected def perform_query(args : Enumerable) : DB::ResultSet
    bind_args(args)
    ResultSet.new(self)
  rescue ex
    close if auto_close && @active_results.empty?
    raise ex
  end

  protected def perform_exec(args : Enumerable) : DB::ExecResult
    bind_args(args)
    state = LibDuckDB.execute_prepared(self, out result)
    begin
      unless state.success?
        message_p = LibDuckDB.result_error(pointerof(result))
        message = message_p.null? ? "Error with command `#{@command}`" : String.new(message_p)
        raise Exception.new(message)
      end
      DB::ExecResult.new LibDuckDB.rows_changed(pointerof(result)).to_i64, 0_i64
    ensure
      LibDuckDB.destroy_result(pointerof(result))
    end
  ensure
    close if auto_close && @active_results.empty?
  end

  # The only streaming execution entry point. Replace this method when a stable
  # successor to DuckDB's deprecated streaming C API is available.
  protected def execute_streaming(result : LibDuckDB::Result*) : LibDuckDB::State
    LibDuckDB.execute_prepared_streaming(self, result)
  end

  # :nodoc:
  def result_opened(result : ResultSet)
    @active_results.add(result)
  end

  # :nodoc:
  def result_closed(result : ResultSet)
    @active_results.delete(result)
  end

  # :nodoc:
  def release_from_result_set
    close if auto_close && @active_results.empty?
    release_connection
  end

  protected def do_close
    return if @closing
    @closing = true
    begin
      @active_results.dup.each &.close
    ensure
      LibDuckDB.destroy_prepare(pointerof(@statement))
      @closing = false
    end
  end

  private def bind_args(args : Enumerable)
    raise Exception.new("Statement is closed") if closed?
    @connection.as(Connection).check_query_allowed
    expected = LibDuckDB.nparams(self)
    unless args.size == expected
      raise Exception.new("Expected #{expected} arguments, got #{args.size} for `#{@command}`")
    end
    check LibDuckDB.clear_bindings(self)
    args.each_with_index(1) { |arg, index| bind_arg(index, arg) }
  end

  private def bind_arg(index, value : Nil)
    check LibDuckDB.bind_null(self, index)
  end

  private def bind_arg(index, value : Bool)
    check LibDuckDB.bind_boolean(self, index, value ? 1_u8 : 0_u8)
  end

  {% for name in ["Int8", "Int16", "Int32", "Int64", "UInt8", "UInt16", "UInt32", "UInt64"] %}
    private def bind_arg(index, value : {{name.id}})
      check LibDuckDB.bind_{{name.id.downcase}}(self, index, value)
    end
  {% end %}

  private def bind_arg(index, value : Int128)
    check LibDuckDB.bind_hugeint(self, index, HugeIntHelper.i128_to_huge(value))
  end

  private def bind_arg(index, value : Float32)
    check LibDuckDB.bind_float(self, index, value)
  end

  private def bind_arg(index, value : Float64)
    check LibDuckDB.bind_double(self, index, value)
  end

  private def bind_arg(index, value : String)
    check LibDuckDB.bind_varchar_length(self, index, value, value.bytesize)
  end

  private def bind_arg(index, value : Date)
    check LibDuckDB.bind_date(self, index, value)
  end

  private def bind_arg(index, value : TimeOfDay)
    check LibDuckDB.bind_time(self, index, value)
  end

  private def bind_arg(index, value : Timestamp)
    check LibDuckDB.bind_timestamp(self, index, value)
  end

  private def bind_arg(index, value : Time)
    bind_arg(index, Timestamp.new(value))
  end

  private def bind_arg(index, value : Interval)
    check LibDuckDB.bind_interval(self, index, value)
  end

  private def bind_arg(index, value : Bytes)
    check LibDuckDB.bind_blob(self, index, value, value.size)
  end

  private def bind_arg(index, value)
    raise "#{self.class} does not support #{value.class} params"
  end

  private def check(state)
    unless state.success?
      message_p = LibDuckDB.prepare_error(self)
      message = message_p.null? ? "Failed to bind parameters for `#{@command}` (check parameter types and UTF-8 strings)" : String.new(message_p)
      raise Exception.new(message)
    end
  end

  protected def duckdb_connection
    @connection.as(Connection).to_unsafe
  end

  def to_unsafe
    @statement
  end
end
