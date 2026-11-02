class DuckDB::UnpreparedStatement < DB::Statement
  def initialize(connection, command)
    super(connection, command)
    raise Exception.new("SQL text contains a NUL byte") if command.includes?('\0')
  end

  protected def perform_query(args : Enumerable) : DB::ResultSet
    raise Exception.new("Unprepared statement exec/query with args is not supported") if args.size > 0
    @connection.as(Connection).check_query_allowed
    if @connection.as(Connection).stream_results && single_statement?
      statement = Statement.new(@connection, @command)
      statement.auto_close = true
      close if auto_close
      return statement.query
    end
    ResultSet.new self
  rescue ex
    close if auto_close
    raise ex
  end

  protected def perform_exec(args : Enumerable) : DB::ExecResult
    raise Exception.new("Unprepared statement exec/query with args is not supported") if args.size > 0

    @connection.as(Connection).check_query_allowed
    state = LibDuckDB.query(duckdb_connection, @command, out result)
    begin
      unless state.success?
        message_p = LibDuckDB.result_error(pointerof(result))
        message = message_p.null? ? "Error with command `#{@command}`" : String.new(message_p)
        raise Exception.new(message)
      end
      rows_changed = LibDuckDB.rows_changed(pointerof(result)).to_i64
      DB::ExecResult.new rows_changed, 0_i64
    ensure
      LibDuckDB.destroy_result(pointerof(result))
    end
  ensure
    close if auto_close
  end

  protected def duckdb_connection
    @connection.as(Connection).to_unsafe
  end

  private def single_statement? : Bool
    count = LibDuckDB.extract_statements(duckdb_connection, @command, out extracted)
    begin
      message_p = LibDuckDB.extract_statements_error(extracted)
      raise Exception.new(String.new(message_p)) unless message_p.null?
      count == 1
    ensure
      LibDuckDB.destroy_extracted(pointerof(extracted))
    end
  end

end
