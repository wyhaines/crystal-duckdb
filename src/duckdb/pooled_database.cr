# A crystal-db pool sharing one DuckDB database.
class DuckDB::PooledDatabase < DB::Database
  @close_mutex = Mutex.new
  @connections_mutex = Mutex.new
  @connections = Set(DB::Connection).new
  @closed = false
  @closing = false
  @initializing = true

  def initialize(options : DB::Connection::Options, pool_options : DB::Pool::Options, @builder : Driver::ConnectionBuilder)
    @builder.retain_database
    begin
      super(options, pool_options) { build_connection }
      @initializing = false
    rescue ex
      # The base pool can fail after building some initial connections, before
      # assigning @pool. Clean up those connections without accessing @pool.
      close_connections
      @builder.close
      raise ex
    end
  end

  private def build_connection : DB::Connection
    @close_mutex.synchronize do
      raise Exception.new("Database pool is closed") if @closed
      connection = @builder.build
      @connections_mutex.synchronize { @connections.add(connection) }
      connection
    end
  end

  # Checks out one connection for the entire chunk iteration, returning it on
  # every exit path. The stream flag overrides that connection's default.
  def each_chunk(sql : String, *args, stream : Bool = false, & : DataChunk ->) : Nil
    using_connection do |connection|
      connection.as(Connection).each_chunk(sql, *args, stream: stream) { |chunk| yield chunk }
    end
  end

  def close
    @close_mutex.synchronize do
      return if @closed
      @closing = true
      begin
        error = close_connections
        super
        raise error if error
      ensure
        @builder.close
        @closed = true
        @closing = false
      end
    end
  end

  private def close_connections
    connections = @connections_mutex.synchronize { @connections.to_a }
    error = nil
    connections.each do |connection|
      begin
        connection.close
      rescue ex
        error ||= ex
      end
    end
    error
  end

  # Close a snapshot of our connections before DB::Pool#close clears its arrays.
  # Connection#close otherwise removes entries from the array being iterated.
  def discard(connection : DB::Connection)
    @connections_mutex.synchronize { @connections.delete(connection) }
    super unless @closing || @initializing
  end
end

module DB
  # crystal-db 0.13.1, 0.14.x and 0.15.x provide no builder/pool-close hook.
  # Intercept only DuckDB pool construction and leave other drivers alone.
  private def self.build_database(uri : URI)
    driver = build_driver(uri)
    return previous_def unless driver.is_a?(DuckDB::Driver)
    params = HTTP::Params.parse(uri.query || "")
    builder = driver.connection_builder(uri).as(DuckDB::Driver::ConnectionBuilder)
    DuckDB::PooledDatabase.new(driver.connection_options(params), driver.pool_options(params), builder)
  end
end
