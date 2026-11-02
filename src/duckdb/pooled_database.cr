# A crystal-db pool sharing one DuckDB database.
class DuckDB::PooledDatabase < DB::Database
  @close_mutex = Mutex.new
  @connections_mutex = Mutex.new
  @connections = Set(DB::Connection).new
  @closed = false
  @initializing = true

  def initialize(options : DB::Connection::Options, pool_options : DB::Pool::Options, @builder : Driver::ConnectionBuilder)
    @connection_options = options
    @setup_connection = ->(conn : DB::Connection) { }
    @pool = uninitialized DB::Pool(DB::Connection)
    @builder.retain_database
    begin
      @pool = DuckDB::Pool.new(pool_options) { build_connection }
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
      connection.auto_release = false
      connection.context = self
      begin
        @setup_connection.call connection
      rescue ex
        connection.close
        raise ex
      end
      connection
    end
  end

  def setup_connection(&proc : DB::Connection -> Nil)
    @close_mutex.synchronize do
      super do |connection|
        # Idle connections have auto_release enabled by their last checkout.
        # The setup callback owns them until it returns, just like a checkout.
        auto_release = connection.auto_release
        connection.auto_release = false
        begin
          proc.call(connection)
        ensure
          connection.auto_release = auto_release
        end
      end
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
      begin
        super
      ensure
        @builder.close
        @closed = true
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

  def discard(connection : DB::Connection)
    @connections_mutex.synchronize { @connections.delete(connection) }
    super unless @initializing
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
