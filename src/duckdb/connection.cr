class DuckDB::Connection < DB::Connection
  @appenders = Set(Appender).new

  record Options, filename : String, config_params : Hash(String, String) do
    CRYSTAL_DB_PARAM_KEYS = %w[
      initial_pool_size
      max_pool_size
      max_idle_pool_size
      checkout_timeout
      retry_attempts
      retry_delay
      prepared_statements
      prepared_statements_cache
    ]

    def initialize(@filename, @config_params)
    end

    def self.from_uri(uri : URI)
      filename = URI.decode((uri.host || "") + uri.path)
      if filename.starts_with?("[:memory:") && filename.ends_with?(']')
        filename = filename[1...-1]
      end
      params = HTTP::Params.parse(uri.query || "")
      config_params = Hash(String, String).new
      params.each do |param|
        config_params[param[0]] = param[1] unless CRYSTAL_DB_PARAM_KEYS.includes?(param[0])
      end
      Options.new(filename, config_params)
    end
  end

  def initialize(options : ::DB::Connection::Options, duckdb_options : Options)
    initialize(options, Database.new(duckdb_options))
  end

  # :nodoc:
  def initialize(options : ::DB::Connection::Options, @database : Database)
    super(options)
    @conn = @database.connect
  end

  def appender(table_name)
    Appender.new(self, table_name)
  end

  def appender(table_name, &block)
    appender = Appender.new(self, table_name)
    yield appender
  ensure
    appender.try &.close
  end

  def do_close
    error = nil
    @appenders.dup.each do |appender|
      begin
        appender.close
      rescue ex
        error ||= ex
      end
    end
    begin
      super
    ensure
      @database.disconnect(pointerof(@conn))
    end
    raise error if error
  end

  # :nodoc:
  def register_appender(appender : Appender)
    @appenders.add(appender)
  end

  # :nodoc:
  def unregister_appender(appender : Appender)
    @appenders.delete(appender)
  end

  def build_prepared_statement(query) : Statement
    Statement.new(self, query)
  end

  def driver_name : String
    "duckdb"
  end

  def build_unprepared_statement(query) : UnpreparedStatement
    UnpreparedStatement.new(self, query)
  end

  def to_unsafe
    @conn
  end

end
