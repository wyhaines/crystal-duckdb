class DuckDB::Driver < DB::Driver
  class ConnectionBuilder < ::DB::ConnectionBuilder
    @mutex = Mutex.new
    @database : Database?
    @pooled = false
    @closed = false

    def initialize(@options : ::DB::Connection::Options, @duckdb_options : Connection::Options)
    end

    # :nodoc:
    def retain_database
      @mutex.synchronize do
        @pooled = true
        @database ||= Database.new(@duckdb_options, retained: true)
      end
    end

    def build : ::DB::Connection
      @mutex.synchronize do
        raise Exception.new("Database pool is closed") if @closed
        loop do
          database = @database
          if database.nil? || database.closed?
            database = @database = Database.new(@duckdb_options, retained: @pooled)
          end
          begin
            return Connection.new(@options, database, @duckdb_options.stream_results)
          rescue Database::ClosedError
            # The last standalone connection can disconnect after closed?
            # but before connect takes the owner's mutex. Retry a fresh owner.
            @database = nil
          end
        end
      end
    end

    # :nodoc:
    def close
      @mutex.synchronize do
        @closed = true
        @database.try &.close
      end
    end
  end

  def connection_builder(uri : URI) : ::DB::ConnectionBuilder
    params = HTTP::Params.parse(uri.query || "")
    ConnectionBuilder.new(connection_options(params), DuckDB::Connection::Options.from_uri(uri))
  end

end

DB.register_driver "duckdb", DuckDB::Driver
