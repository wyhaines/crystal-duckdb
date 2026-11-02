class DuckDB::Connection < DB::Connection
  @appenders = Set(Appender).new
  @results = Set(ResultSet).new
  @streaming_result : ResultSet?

  # Opt in for subsequent prepared and unprepared queries. Exec stays materialized.
  property stream_results : Bool = false

  record Options, filename : String, config_params : Hash(String, String), stream_results : Bool = false do
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

    def initialize(@filename, @config_params, @stream_results = false)
    end

    def self.from_uri(uri : URI)
      filename = URI.decode((uri.host || "") + uri.path)
      if filename.starts_with?("[:memory:") && filename.ends_with?(']')
        filename = filename[1...-1]
      end
      params = HTTP::Params.parse(uri.query || "")
      config_params = Hash(String, String).new
      params.each do |param|
        config_params[param[0]] = param[1] unless CRYSTAL_DB_PARAM_KEYS.includes?(param[0]) || param[0] == "stream_results"
      end
      Options.new(filename, config_params, DB.fetch_bool(params, "stream_results", false))
    end
  end

  def initialize(options : ::DB::Connection::Options, duckdb_options : Options)
    initialize(options, Database.new(duckdb_options), duckdb_options.stream_results)
  end

  # :nodoc:
  def initialize(options : ::DB::Connection::Options, @database : Database, @stream_results : Bool = false)
    super(options)
    @conn = @database.connect
  end

  # Opens an appender using literal identifiers, without splitting table on dots.
  def appender(table : String, schema : String? = nil, catalog : String? = nil)
    Appender.new(self, table, schema, catalog)
  end

  # Yields an appender and closes it on every exit path.
  def appender(table : String, schema : String? = nil, catalog : String? = nil, &block)
    appender = Appender.new(self, table, schema, catalog)
    yield appender
  ensure
    appender.try &.close
  end

  # Executes one prepared SQL statement and yields each borrowed result chunk.
  # Bindings and guards match query. The explicit stream setting overrides
  # stream_results for this call. Chunks and vectors expire at each block exit.
  def each_chunk(sql : String, *args, stream : Bool = false, & : DataChunk ->) : Nil
    statement = build_prepared_statement(sql)
    begin
      result = statement.query_chunks(args, stream)
      result.each_chunk { |chunk| yield chunk }
    ensure
      result.try &.close
      statement.close
    end
  end

  def do_close
    @results.dup.each &.close
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

  # :nodoc:
  def check_query_allowed
    raise Exception.new("Connection is closed") if closed?
    if @streaming_result
      raise Exception.new("Close or exhaust the active streaming result before running another query on this connection")
    end
  end

  # :nodoc:
  def register_result(result : ResultSet, streaming : Bool)
    @results.add(result)
    @streaming_result = result if streaming
  end

  # :nodoc:
  def finish_stream(result : ResultSet)
    @streaming_result = nil if @streaming_result.same?(result)
  end

  # :nodoc:
  def unregister_result(result : ResultSet)
    finish_stream(result)
    @results.delete(result)
  end

  def release_from_statement
    super if @results.empty?
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
