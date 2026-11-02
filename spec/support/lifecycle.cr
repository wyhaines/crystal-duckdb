# Native handle counts keep cleanup assertions independent of the reader implementation.
@[Link(ldflags: "#{__DIR__}/lifecycle.c -Wl,--wrap=duckdb_query,--wrap=duckdb_execute_prepared,--wrap=duckdb_destroy_result,--wrap=duckdb_prepare,--wrap=duckdb_destroy_prepare,--wrap=duckdb_appender_create,--wrap=duckdb_appender_destroy,--wrap=duckdb_open,--wrap=duckdb_open_ext,--wrap=duckdb_get_or_create_from_cache,--wrap=duckdb_close,--wrap=duckdb_connect,--wrap=duckdb_disconnect,--wrap=duckdb_create_instance_cache,--wrap=duckdb_destroy_instance_cache,--wrap=duckdb_free,--wrap=duckdb_execute_prepared_streaming,--wrap=duckdb_fetch_chunk,--wrap=duckdb_destroy_data_chunk,--wrap=duckdb_column_logical_type,--wrap=duckdb_destroy_logical_type,--wrap=duckdb_struct_type_child_type,--wrap=duckdb_union_type_member_type,--wrap=duckdb_vector_get_column_type,--wrap=duckdb_list_type_child_type,--wrap=duckdb_array_type_child_type,--wrap=duckdb_map_type_key_type,--wrap=duckdb_map_type_value_type,--wrap=duckdb_extract_statements,--wrap=duckdb_destroy_extracted,--wrap=duckdb_create_uuid,--wrap=duckdb_create_bignum,--wrap=duckdb_create_time_ns,--wrap=duckdb_create_time_tz_value,--wrap=duckdb_create_timestamp_s,--wrap=duckdb_create_timestamp_ms,--wrap=duckdb_create_timestamp_ns,--wrap=duckdb_create_timestamp_tz,--wrap=duckdb_destroy_value,--wrap=duckdb_enum_dictionary_value")]
lib NativeLifetime
  fun extracted_statements = spec_live_extracted_statements : Int64
  fun values = spec_live_values : Int64
  fun enum_dictionary_reads = spec_enum_dictionary_reads : Int64
  fun chunks = spec_live_chunks : Int64
  fun logical_types = spec_live_logical_types : Int64
  fun streaming_executions = spec_streaming_executions : Int64
  fun fetched_chunks = spec_fetched_chunks : Int64
  fun acquired_types = spec_acquired_types : Int64
  fun results = spec_live_results : Int64
  fun statements = spec_live_statements : Int64
  fun appenders = spec_live_appenders : Int64
  fun fail_connect_after = spec_fail_connect_after(count : Int64) : Void
  fun databases = spec_live_databases : Int64
  fun connections = spec_live_connections : Int64
  fun caches = spec_live_caches : Int64
  fun open_errors = spec_live_open_errors : Int64
end
