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

  # :nodoc:
  def query_chunks(args : Enumerable, stream : Bool) : ResultSet
    around_query_or_exec(args) do
      bind_args(args)
      ResultSet.new(self, stream)
    end
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
    return if @closing
    close if auto_close && @active_results.empty?
    release_connection
  end

  def close
    return if @closing
    had_results = !@active_results.empty?
    super
    # Publish the connection only after Disposable has marked this statement
    # closed and do_close has finished destroying its native handle.
    release_connection if had_results
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
    begin
      bind_args_once(args)
    rescue ValueBuilder::ConversionError
      # Parameter metadata can remain stale after DDL. Retry conversion once on
      # a fresh handle, rebinding every argument. If stale metadata accepts the
      # value, execution uses DuckDB's casts and can still lose precision: create
      # a fresh statement after schema changes when exactness is required.
      refresh_preparation
      bind_args_once(args)
    end
  end

  private def bind_args_once(args : Enumerable)
    check LibDuckDB.clear_bindings(self)
    args.each_with_index(1) { |arg, index| bind_arg(index, arg) }
  end

  private def refresh_preparation
    state = LibDuckDB.prepare(duckdb_connection, @command, out replacement)
    unless state.success?
      begin
        error = LibDuckDB.prepare_error(replacement)
        raise Exception.new(error.null? ? "Could not refresh prepared parameter types" : String.new(error))
      ensure
        LibDuckDB.destroy_prepare(pointerof(replacement))
      end
    end
    previous = @statement
    @statement = replacement
    LibDuckDB.destroy_prepare(pointerof(previous))
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

  private def bind_arg(index, value : UInt128)
    check LibDuckDB.bind_uhugeint(self, index, HugeIntHelper.u128_to_uhuge(value))
  end

  private def bind_arg(index, value : Decimal)
    with_parameter_type(index) do |destination, type|
      if type.union?
        bind_owned_value(index, ValueBuilder.build(value, destination))
      else
        scale = type.decimal? ? LibDuckDB.decimal_scale(destination) : 0_u8
        ValueBuilder.check_decimal(value, type, scale)
        check LibDuckDB.bind_decimal(self, index, value)
      end
    end
  end

  private def bind_arg(index, value : UUID)
    bind_owned_value(index, ValueBuilder.scalar(value))
  end

  private def bind_arg(index, value : BigNum)
    bind_owned_value(index, ValueBuilder.scalar(value))
  end

  private def bind_arg(index, value : TimeTZ)
    bind_owned_value(index, ValueBuilder.scalar(value))
  end

  private def with_parameter_type(index, &)
    destination = LibDuckDB.param_logical_type(self, index)
    begin
      type = destination.null? ? LibDuckDB::Type::INVALID : LibDuckDB.get_type_id(destination)
      yield destination, type
    ensure
      LibDuckDB.destroy_logical_type(pointerof(destination)) unless destination.null?
    end
  end

  private def bind_nested_value(index, value)
    with_parameter_type(index) do |destination, _|
      bind_owned_value(index, ValueBuilder.build(value, destination))
    end
  end

  private def bind_arg(index, value : Array | Slice | StaticArray | Hash | NamedTuple)
    bind_nested_value(index, value)
  end

  private def bind_owned_value(index, value : LibDuckDB::Value)
    raise Exception.new("Could not create DuckDB parameter value") if value.null?
    begin
      check LibDuckDB.bind_value(self, index, value)
    ensure
      LibDuckDB.destroy_value(pointerof(value))
    end
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
    with_parameter_type(index) do |destination, type|
      if type.union?
        bind_owned_value(index, ValueBuilder.build(value, destination))
      else
        ValueBuilder.check_precision(value.nanoseconds, type, "TimeOfDay")
        if value.nanoseconds % 1000 == 0
          check LibDuckDB.bind_time(self, index, value)
        else
          bind_owned_value(index, ValueBuilder.scalar(value))
        end
      end
    end
  end

  private def bind_arg(index, value : Timestamp)
    with_parameter_type(index) do |destination, type|
      if type.union?
        bind_owned_value(index, ValueBuilder.build(value, destination))
      else
        ValueBuilder.check_precision(value.nanoseconds, type, "Timestamp") unless value.infinite?
        if !value.timezone? && (value.infinite? || (value.nanoseconds % 1000 == 0 && -Int64::MAX < value.nanoseconds // 1000 < Int64::MAX))
          check LibDuckDB.bind_timestamp(self, index, value)
        else
          bind_owned_value(index, ValueBuilder.scalar(value))
        end
      end
    end
  end

  private def bind_arg(index, value : Time)
    bind_owned_value(index, ValueBuilder.scalar(value))
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

# :nodoc:
module DuckDB::ParameterLog
  def self.convert(arg : T) : ::Log::Metadata::Value forall T
    {% if T.union? %}
      {% for member in T.union_types %}
        return convert(arg.as({{member}})) if arg.is_a?({{member}})
      {% end %}
      raise DuckDB::Exception.new("Unsupported log value")
    {% elsif T < Tuple %}
      values = [] of ::Log::Metadata::Value
      {% for index in 0...T.type_vars.size %}
        values << convert(arg[{{index}}])
      {% end %}
      ::Log::Metadata::Value.new(values)
    {% elsif T < Enumerable && !(T < Range) %}
      values = [] of ::Log::Metadata::Value
      arg.each { |value| values << convert(value) }
      ::Log::Metadata::Value.new(values)
    {% elsif T == Int128 || T == UInt128 %}
      ::Log::Metadata::Value.new(arg.to_s)
    {% else %}
      DB::MetadataValueConverter.arg_to_log(arg)
    {% end %}
  end
end

module DB::MetadataValueConverter
  # :nodoc:
  # Preserve crystal-db's metadata format while keeping recursive aliases out
  # of its to_a/map intermediate and dispatching each union member explicitly.
  # Re-check this crystal-db method's signature and formatting with every release.
  def self.arg_to_log(arg : Enumerable) : ::Log::Metadata::Value
    DuckDB::ParameterLog.convert(arg)
  end
end
