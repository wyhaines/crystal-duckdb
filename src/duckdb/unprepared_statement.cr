class DuckDB::UnpreparedStatement < DB::Statement
  def initialize(connection, command)
    super(connection, command)
  end

  protected def perform_query(args : Enumerable) : DB::ResultSet
    raise Exception.new("Unprepared statement exec/query with args is not supported") if args.size > 0
    ResultSet.new self
  end

  protected def perform_exec(args : Enumerable) : DB::ExecResult
    raise Exception.new("Unprepared statement exec/query with args is not supported") if args.size > 0

    state = LibDuckDB.query(duckdb_connection, @command, out result)
    begin
      unless state.success?
        message_p = LibDuckDB.result_error(pointerof(result))
        message = message_p.null? ? "Error with command `#{@command}`" : String.new(message_p)
        raise Exception.new(message)
      end
      rows_changed = LibDuckDB.rows_changed(pointerof(result)).to_i64
      DB::ExecResult.new rows_changed, rows_changed
    ensure
      LibDuckDB.destroy_result(pointerof(result))
    end
  end

  protected def duckdb_connection
    @connection.as(Connection).to_unsafe
  end

end
