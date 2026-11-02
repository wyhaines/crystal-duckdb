# Native handle counts keep cleanup assertions independent of the reader implementation.
@[Link(ldflags: "#{__DIR__}/lifecycle.c -Wl,--wrap=duckdb_query,--wrap=duckdb_execute_prepared,--wrap=duckdb_destroy_result,--wrap=duckdb_prepare,--wrap=duckdb_destroy_prepare,--wrap=duckdb_appender_create,--wrap=duckdb_appender_destroy,--wrap=duckdb_open_ext,--wrap=duckdb_free")]
lib NativeLifetime
  fun results = spec_live_results : Int64
  fun statements = spec_live_statements : Int64
  fun appenders = spec_live_appenders : Int64
  fun open_errors = spec_live_open_errors : Int64
end
