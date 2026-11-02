# Guard counter reads, assertions and snapshot helper definitions with this macro.
# NativeLifetime is absent without --wrap, so an unguarded new counter fails to compile.
# Force that configuration on Linux with crystal spec -Dno_native_lifetime.
macro native_lifetime(&block)
  {% if flag?(:linux) && !flag?(:no_native_lifetime) %}
    {{block.body}}
  {% else %}
    nil
  {% end %}
end

# Failure injection also needs the shim; behavioral specs use native_lifetime
# only around their counter expressions and still run on every platform.
macro native_lifetime_it(description, &block)
  {% if flag?(:linux) && !flag?(:no_native_lifetime) %}
    it {{description}} do
      {{block.body}}
    end
  {% else %}
    pending {{description}}
  {% end %}
end

{% if flag?(:linux) && !flag?(:no_native_lifetime) %}
  # Native handle counts keep cleanup assertions independent of the reader implementation.
  @[Link(ldflags: "#{__DIR__}/lifecycle.c -Wl,--wrap=duckdb_query,--wrap=duckdb_execute_prepared,--wrap=duckdb_destroy_result,--wrap=duckdb_prepare,--wrap=duckdb_destroy_prepare,--wrap=duckdb_appender_create,--wrap=duckdb_appender_create_ext,--wrap=duckdb_appender_column_type,--wrap=duckdb_create_decimal,--wrap=duckdb_appender_destroy,--wrap=duckdb_open,--wrap=duckdb_open_ext,--wrap=duckdb_get_or_create_from_cache,--wrap=duckdb_close,--wrap=duckdb_connect,--wrap=duckdb_disconnect,--wrap=duckdb_create_instance_cache,--wrap=duckdb_destroy_instance_cache,--wrap=duckdb_free,--wrap=duckdb_execute_prepared_streaming,--wrap=duckdb_fetch_chunk,--wrap=duckdb_destroy_data_chunk,--wrap=duckdb_create_data_chunk,--wrap=duckdb_append_data_chunk,--wrap=duckdb_column_logical_type,--wrap=duckdb_destroy_logical_type,--wrap=duckdb_struct_type_child_type,--wrap=duckdb_union_type_member_type,--wrap=duckdb_vector_get_column_type,--wrap=duckdb_list_type_child_type,--wrap=duckdb_array_type_child_type,--wrap=duckdb_map_type_key_type,--wrap=duckdb_map_type_value_type,--wrap=duckdb_extract_statements,--wrap=duckdb_destroy_extracted,--wrap=duckdb_create_uuid,--wrap=duckdb_create_bignum,--wrap=duckdb_create_time_ns,--wrap=duckdb_create_time_tz_value,--wrap=duckdb_create_timestamp_s,--wrap=duckdb_create_timestamp_ms,--wrap=duckdb_create_timestamp_ns,--wrap=duckdb_create_timestamp_tz,--wrap=duckdb_destroy_value,--wrap=duckdb_enum_dictionary_value,--wrap=dlsym,--wrap=duckdb_append_value,--wrap=duckdb_bind_decimal,--wrap=duckdb_bind_time,--wrap=duckdb_bind_timestamp,--wrap=duckdb_bind_value,--wrap=duckdb_create_array_type,--wrap=duckdb_create_array_value,--wrap=duckdb_create_blob,--wrap=duckdb_create_bool,--wrap=duckdb_create_date,--wrap=duckdb_create_double,--wrap=duckdb_create_float,--wrap=duckdb_create_hugeint,--wrap=duckdb_create_int16,--wrap=duckdb_create_int32,--wrap=duckdb_create_int64,--wrap=duckdb_create_int8,--wrap=duckdb_create_interval,--wrap=duckdb_create_list_type,--wrap=duckdb_create_list_value,--wrap=duckdb_create_logical_type,--wrap=duckdb_create_map_type,--wrap=duckdb_create_map_value,--wrap=duckdb_create_null_value,--wrap=duckdb_create_struct_type,--wrap=duckdb_create_struct_value,--wrap=duckdb_create_time,--wrap=duckdb_create_timestamp,--wrap=duckdb_create_uhugeint,--wrap=duckdb_create_uint16,--wrap=duckdb_create_uint32,--wrap=duckdb_create_uint64,--wrap=duckdb_create_uint8,--wrap=duckdb_create_union_value,--wrap=duckdb_create_varchar_length,--wrap=duckdb_param_logical_type")]
  lib NativeLifetime
    fun extracted_statements = spec_live_extracted_statements : Int64
    fun values = spec_live_values : Int64
    fun enum_dictionary_reads = spec_enum_dictionary_reads : Int64
    fun created_chunks = spec_created_chunks : Int64
    fun appended_chunks = spec_appended_chunks : Int64
    fun fail_create_chunk_after = spec_fail_create_chunk_after(count : Int64) : Void
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
    fun preparations = spec_preparations : Int64
    fun timestamp_binds = spec_timestamp_binds : Int64
    fun time_binds = spec_time_binds : Int64
    fun decimal_binds = spec_decimal_binds : Int64
    fun fail_value_after = spec_fail_value_after(count : Int64) : Void
    fun fail_type_after = spec_fail_type_after(count : Int64) : Void
    fun fail_bind_value = spec_fail_bind_value(fail : Int32) : Void
    fun fail_append_value = spec_fail_append_value(fail : Int32) : Void
    fun tz_ns_lookups = spec_tz_ns_lookups : Int64
  end
{% else %}
  describe "Native lifetime instrumentation" do
    pending "native handle counter assertions require Linux linker --wrap (or omit -Dno_native_lifetime)"
  end
{% end %}
