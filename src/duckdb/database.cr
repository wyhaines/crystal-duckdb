require "./exception"

# :nodoc:
# DuckDB's cache uses normalized file paths (and exact named-memory paths).
# Keep one process-wide cache while any cached database handle is alive.
class DuckDB::InstanceCache
  @@mutex = Mutex.new
  @@cache = Pointer(Void).null.as(LibDuckDB::InstanceCache)
  @@users = 0

  def self.open(filename : String, config : LibDuckDB::Config) : LibDuckDB::Database
    @@mutex.synchronize do
      @@cache = LibDuckDB.create_instance_cache if @@cache.null?
      raise Exception.new("Could not create database instance cache") if @@cache.null?
      database = Pointer(Void).null.as(LibDuckDB::Database)
      error = Pointer(LibC::Char).null
      begin
        state = LibDuckDB.get_or_create_from_cache(@@cache, filename, pointerof(database), config, pointerof(error))
        unless state.success?
          raise Exception.new(error.null? ? "Database open error" : String.new(error))
        end
        @@users += 1
        database
      rescue ex
        LibDuckDB.close(pointerof(database)) unless database.null?
        raise ex
      ensure
        LibDuckDB.free(error) unless error.null?
        destroy_cache if @@users == 0
      end
    end
  end

  def self.close(database : LibDuckDB::Database*)
    @@mutex.synchronize do
      LibDuckDB.close(database)
      @@users -= 1
      destroy_cache if @@users == 0
    end
  end

  private def self.destroy_cache
    # Use a local out-pointer: on the installed compiler, the first
    # pointerof(@@cache) reinitializes the class variable and loses its handle.
    cache = @@cache
    @@cache = Pointer(Void).null.as(LibDuckDB::InstanceCache)
    LibDuckDB.destroy_instance_cache(pointerof(cache))
  end
end

# :nodoc:
# One native database per ConnectionBuilder. A pool retains its owner even when
# it has no connections; standalone connections release it on last disconnect.
class DuckDB::Database
  # :nodoc:
  class ClosedError < DuckDB::Exception
  end

  @mutex = Mutex.new
  @db = Pointer(Void).null.as(LibDuckDB::Database)
  @connections = 0
  @cached : Bool

  def initialize(options : Connection::Options, @retained = false)
    @cached = !options.filename.empty? && options.filename != ":memory:"
    config = Pointer(Void).null.as(LibDuckDB::Config)
    error = Pointer(LibC::Char).null
    begin
      unless options.config_params.empty?
        state = LibDuckDB.create_config(pointerof(config))
        raise Exception.new("Could not create database configuration") unless state.success?
        options.config_params.each do |key, value|
          state = LibDuckDB.set_config(config, key, value)
          raise Exception.new("Configuration error for '#{key}' with value '#{value}'") unless state.success?
        end
      end
      if @cached
        @db = InstanceCache.open(options.filename, config)
      else
        state = LibDuckDB.open_ext(options.filename, pointerof(@db), config, pointerof(error))
        unless state.success?
          raise Exception.new(error.null? ? "Database open error" : String.new(error))
        end
      end
    rescue ex
      LibDuckDB.close(pointerof(@db)) unless @db.null?
      raise ex
    ensure
      LibDuckDB.free(error) unless error.null?
      LibDuckDB.destroy_config(pointerof(config)) unless config.null?
    end
  end

  def closed? : Bool
    @mutex.synchronize { @db.null? }
  end

  def connect : LibDuckDB::Connection
    @mutex.synchronize do
      raise ClosedError.new("Database is closed") if @db.null?
      state = LibDuckDB.connect(@db, out connection)
      unless state.success?
        LibDuckDB.disconnect(pointerof(connection)) unless connection.null?
        close_handle unless @retained || @connections > 0
        raise Exception.new("Connection error")
      end
      @connections += 1
      connection
    end
  end

  def disconnect(connection : LibDuckDB::Connection*)
    @mutex.synchronize do
      return if connection.value.null?
      LibDuckDB.disconnect(connection)
      @connections -= 1
      close_handle unless @retained || @connections > 0
    end
  end

  def close
    @mutex.synchronize do
      @retained = false
      close_handle if @connections == 0
    end
  end

  private def close_handle
    return if @db.null?
    if @cached
      InstanceCache.close(pointerof(@db))
    else
      LibDuckDB.close(pointerof(@db))
    end
  end
end
