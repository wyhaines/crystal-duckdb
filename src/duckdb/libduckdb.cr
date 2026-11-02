module DuckDB
  @[Link("duckdb")]
  lib LibDuckDB
    alias CBool = UInt8

    alias Idx = UInt64
    type Database = Void*
    type Connection = Void*
    type PreparedStatement = Void*
    type ExtractedStatements = Void*
    type Appender = Void*
    type Arrow = Void*
    type Config = Void*
    type DataChunk = Void*
    type Vector = Void*
    type LogicalType = Void*
    type Value = Void*

    enum State
      Success = 0
      Error   = 1
    end

    # DuckDB data type.
    enum Type
      # Invalid data type.
      INVALID = 0
      # Treated as `Bool`.
      BOOLEAN = 1
      # Treated as `Int8`.
      TINYINT = 2
      # Treated as `Int16`.
      SMALLINT = 3
      # Treated as `Int32`.
      INTEGER = 4
      # Treated as `Int64`.
      BIGINT = 5
      # Treated as `UInt8`.
      UTINYINT = 6
      # Treated as `UInt16`.
      USMALLINT = 7
      # Treated as `UInt32`.
      UINTEGER = 8
      # Treated as `UInt64`.
      UBIGINT = 9
      # Treated as `Float32`.
      FLOAT = 10
      # Treated as `Float64`.
      DOUBLE = 11
      # Treated as `Time`.
      TIMESTAMP = 12
      # Treated as `DuckDB::Date`.
      DATE = 13
      # Treated as `DuckDB::TimeOfDay`.
      TIME = 14
      # Treated as `DuckDB::Interval`.
      INTERVAL = 15
      # Treated as `Int128`.
      HUGEINT = 16
      # Treated as `String`.
      VARCHAR = 17
      # Treated as `Bytes`.
      BLOB = 18
      # Additional DuckDB types.
      DECIMAL = 19
      TIMESTAMP_S = 20
      TIMESTAMP_MS = 21
      TIMESTAMP_NS = 22
      ENUM = 23
      LIST = 24
      STRUCT = 25
      MAP = 26
      UUID = 27
      UNION = 28
      BIT = 29
      TIME_TZ = 30
      TIMESTAMP_TZ = 31
      UHUGEINT = 32
      ARRAY = 33
      ANY = 34
      BIGNUM = 35
      SQLNULL = 36
      STRING_LITERAL = 37
      INTEGER_LITERAL = 38
      TIME_NS = 39
      GEOMETRY = 40
      VARIANT = 41
      TIMESTAMP_TZ_NS = 42
    end


    enum ResultType
      INVALID = 0
      CHANGED_ROWS = 1
      NOTHING = 2
      QUERY_RESULT = 3
    end

    # The union's pointer variant determines its size and alignment (16 / 8).
    struct StringT
      length : UInt32
      prefix : StaticArray(UInt8, 4)
      ptr : UInt8*
    end

    struct ListEntry
      offset : Idx
      length : Idx
    end

    struct DateParts
      year : Int32
      month : Int8
      day : Int8
    end

    struct TimeParts
      hour : Int8
      min : Int8
      sec : Int8
      micros : Int32
    end

    struct Date
      # Days are stored as days since 1970-01-01
      days : Int32
    end

    struct Time
      # Time is stored as microseconds since 00:00:00
      micros : Int64
    end

    struct Timestamp
      # Time is stored as microseconds since 1970-01-01
      micros : Int64
    end

    struct Interval
      months : Int32
      days : Int32
      micros : Int64
    end

    struct HugeInt
      lower : UInt64
      upper : Int64
    end

    struct UHugeInt
      lower : UInt64
      upper : UInt64
    end

    struct TimeNS
      nanos : Int64
    end

    struct TimestampS
      seconds : Int64
    end

    struct TimestampMS
      millis : Int64
    end

    struct TimestampNS
      nanos : Int64
    end

    struct BigNum
      data : UInt8*
      size : Idx
      is_negative : CBool
    end

    struct TimeTZ
      bits : UInt64
    end

    struct TimeTZParts
      time : TimeParts
      offset : Int32
    end

    struct Decimal
      width : UInt8
      scale : UInt8
      value : HugeInt
    end

    struct String
      data : LibC::Char*
      size : Idx
    end

    struct Blob
      data : Void*
      size : Idx
    end

    struct Column
      data : Void*
      nullmask : CBool*
      type : Type
      name : LibC::Char*
      internal_data : Void*
    end

    struct Result
      column_count : Idx
      row_count : Idx
      rows_changed : Idx
      columns : Column*
      error_message : LibC::Char*
      internal_data : Void*
    end

    # Database instance cache (stable and exported in DuckDB 1.5.6 and 2.0).
    type InstanceCache = Void*
    fun create_instance_cache = duckdb_create_instance_cache : InstanceCache
    fun get_or_create_from_cache = duckdb_get_or_create_from_cache(instance_cache : InstanceCache, path : LibC::Char*, out_database : Database*, config : Config, out_error : LibC::Char**) : State
    fun destroy_instance_cache = duckdb_destroy_instance_cache(instance_cache : InstanceCache*) : Void

    # # NOTE: ARROW FUNCTIONS NOT IMPLEMENTED

    # Opens a database file at the given path (nullptr for in-memory). Returns State::Success on success, or State::Error on
    # failure. [OUT: Database]
    fun open = duckdb_open(path : LibC::Char*, out_database : Database*) : State
    # Closes the database.
    fun close = duckdb_close(database : Database*) : Void

    # Extended version of duckdb_open. Creates a new database or opens an existing database file stored at the the given path.
    # configuration used to start up the database system
    # Returns State::Success on success, or State::Error on failure. [OUT: Database]
    fun open_ext = duckdb_open_ext(path : LibC::Char*, out_database : Database*, config : Config, out_error : LibC::Char**) : State

    # Creates a connection to the specified database. [OUT: connection]
    fun connect = duckdb_connect(database : Database, out_connection : Connection*) : State
    # Closes the specified connection handle
    fun disconnect = duckdb_disconnect(connection : Connection*) : Void


    # Initializes an empty configuration object that can be used to provide start-up options for the DuckDB instance
    # through `open_ext`
    fun create_config = duckdb_create_config(out_config : Config*) : State

    # Sets the specified option for the specified configuration. The configuration option is indicated by name.
    fun set_config = duckdb_set_config(config : Config, name : LibC::Char*, option : LibC::Char*) : State

    # Destroys the specified configuration option and de-allocates all memory allocated for the object.
    fun destroy_config = duckdb_destroy_config(config : Config*) : Void

    # Executes the specified SQL query in the specified connection handle. [OUT: result descriptor]
    fun query = duckdb_query(connection : Connection, query : LibC::Char*, out_result : Result*) : State
    # Destroys the specified result
    fun destroy_result = duckdb_destroy_result(result : Result*) : Void

    # Returns the column name of the specified column. The result does not need to be freed :
    # the column names will automatically be destroyed when the result is destroyed.
    fun column_name = duckdb_column_name(result : Result*, col : Idx) : LibC::Char*

    # Returns the column type of the specified column :
    # Returns `INVALID` if the column is out of range.
    fun column_type = duckdb_column_type(result : Result*, col : Idx) : Type

    # Returns the number of columns present in the result object.
    fun column_count = duckdb_column_count(result : Result*) : Idx

    # Returns the number of rows changed by the query stored in the result.
    # This is relevant only for INSERT/UPDATE/DELETE queries.
    # For other queries the rows_changed will be 0.
    fun rows_changed = duckdb_rows_changed(result : Result*) : Idx

    # Returns the error message contained within the result.
    # The error is only set if `duckdb_query` returns `DuckDBError`.
    fun result_error = duckdb_result_error(result : Result*) : LibC::Char*


    # Chunks and logical types returned by these functions are owned by the caller.
    # fetch_chunk and result_return_type take the result BY VALUE.
    fun create_data_chunk = duckdb_create_data_chunk(types : LogicalType*, column_count : Idx) : DataChunk
    fun data_chunk_reset = duckdb_data_chunk_reset(chunk : DataChunk) : Void
    fun data_chunk_set_size = duckdb_data_chunk_set_size(chunk : DataChunk, size : Idx) : Void
    fun vector_size = duckdb_vector_size : Idx
    fun vector_ensure_validity_writable = duckdb_vector_ensure_validity_writable(vector : Vector) : Void
    fun vector_assign_string_element_len = duckdb_vector_assign_string_element_len(vector : Vector, index : Idx, str : LibC::Char*, length : Idx) : Void
    fun append_data_chunk = duckdb_append_data_chunk(appender : Appender, chunk : DataChunk) : State
    fun fetch_chunk = duckdb_fetch_chunk(result : Result) : DataChunk
    fun destroy_data_chunk = duckdb_destroy_data_chunk(chunk : DataChunk*) : Void
    fun data_chunk_get_size = duckdb_data_chunk_get_size(chunk : DataChunk) : Idx
    fun data_chunk_get_column_count = duckdb_data_chunk_get_column_count(chunk : DataChunk) : Idx
    fun data_chunk_get_vector = duckdb_data_chunk_get_vector(chunk : DataChunk, col : Idx) : Vector
    fun vector_get_data = duckdb_vector_get_data(vector : Vector) : Void*
    fun vector_get_validity = duckdb_vector_get_validity(vector : Vector) : UInt64*
    fun vector_get_column_type = duckdb_vector_get_column_type(vector : Vector) : LogicalType
    fun column_logical_type = duckdb_column_logical_type(result : Result*, col : Idx) : LogicalType
    fun get_type_id = duckdb_get_type_id(type : LogicalType) : Type
    fun destroy_logical_type = duckdb_destroy_logical_type(type : LogicalType*) : Void
    fun decimal_width = duckdb_decimal_width(type : LogicalType) : UInt8
    fun decimal_scale = duckdb_decimal_scale(type : LogicalType) : UInt8
    fun decimal_internal_type = duckdb_decimal_internal_type(type : LogicalType) : Type
    fun enum_internal_type = duckdb_enum_internal_type(type : LogicalType) : Type
    fun enum_dictionary_size = duckdb_enum_dictionary_size(type : LogicalType) : UInt32
    fun enum_dictionary_value = duckdb_enum_dictionary_value(type : LogicalType, index : Idx) : LibC::Char*
    fun list_type_child_type = duckdb_list_type_child_type(type : LogicalType) : LogicalType
    fun list_vector_get_child = duckdb_list_vector_get_child(vector : Vector) : Vector
    fun list_vector_get_size = duckdb_list_vector_get_size(vector : Vector) : Idx
    fun struct_type_child_count = duckdb_struct_type_child_count(type : LogicalType) : Idx
    fun struct_type_child_type = duckdb_struct_type_child_type(type : LogicalType, index : Idx) : LogicalType
    fun struct_type_child_name = duckdb_struct_type_child_name(type : LogicalType, index : Idx) : LibC::Char*
    fun struct_vector_get_child = duckdb_struct_vector_get_child(vector : Vector, index : Idx) : Vector
    fun array_type_child_type = duckdb_array_type_child_type(type : LogicalType) : LogicalType
    fun array_type_array_size = duckdb_array_type_array_size(type : LogicalType) : Idx
    fun array_vector_get_child = duckdb_array_vector_get_child(vector : Vector) : Vector
    fun map_type_key_type = duckdb_map_type_key_type(type : LogicalType) : LogicalType
    fun map_type_value_type = duckdb_map_type_value_type(type : LogicalType) : LogicalType
    fun union_type_member_count = duckdb_union_type_member_count(type : LogicalType) : Idx
    fun union_type_member_name = duckdb_union_type_member_name(type : LogicalType, index : Idx) : LibC::Char*
    fun union_type_member_type = duckdb_union_type_member_type(type : LogicalType, index : Idx) : LogicalType
    fun string_is_inlined = duckdb_string_is_inlined(string : StringT) : CBool
    fun string_t_length = duckdb_string_t_length(string : StringT) : UInt32
    fun string_t_data = duckdb_string_t_data(string : StringT*) : LibC::Char*
    fun result_return_type = duckdb_result_return_type(result : Result) : ResultType
    fun result_error_type = duckdb_result_error_type(result : Result*) : Int32
    fun from_date = duckdb_from_date(date : Date) : DateParts
    fun from_time = duckdb_from_time(time : Time) : TimeParts
    fun is_finite_date = duckdb_is_finite_date(date : Date) : CBool
    fun is_finite_timestamp = duckdb_is_finite_timestamp(timestamp : Timestamp) : CBool

    fun from_time_tz = duckdb_from_time_tz(time : TimeTZ) : TimeTZParts
    fun create_time_tz = duckdb_create_time_tz(micros : Int64, offset : Int32) : TimeTZ
    fun bind_decimal = duckdb_bind_decimal(statement : PreparedStatement, index : Idx, value : Decimal) : State
    fun bind_uhugeint = duckdb_bind_uhugeint(statement : PreparedStatement, index : Idx, value : UHugeInt) : State
    fun bind_value = duckdb_bind_value(statement : PreparedStatement, index : Idx, value : Value) : State
    fun create_uuid = duckdb_create_uuid(value : UHugeInt) : Value
    fun create_time_ns = duckdb_create_time_ns(value : TimeNS) : Value
    fun create_time_tz_value = duckdb_create_time_tz_value(value : TimeTZ) : Value
    fun create_timestamp_s = duckdb_create_timestamp_s(value : TimestampS) : Value
    fun create_timestamp_ms = duckdb_create_timestamp_ms(value : TimestampMS) : Value
    fun create_timestamp_ns = duckdb_create_timestamp_ns(value : TimestampNS) : Value
    fun create_timestamp_tz = duckdb_create_timestamp_tz(value : Timestamp) : Value
    fun create_bignum = duckdb_create_bignum(value : BigNum) : Value
    fun append_value = duckdb_append_value(appender : Appender, value : Value) : State
    fun destroy_value = duckdb_destroy_value(value : Value*) : Void

    # get_value_type borrows from the value; it must NOT be destroyed.
    fun get_value_type = duckdb_get_value_type(value : Value) : LogicalType
    fun param_logical_type = duckdb_param_logical_type(statement : PreparedStatement, index : Idx) : LogicalType
    fun create_logical_type = duckdb_create_logical_type(type : Type) : LogicalType
    fun create_list_type = duckdb_create_list_type(child : LogicalType) : LogicalType
    fun create_array_type = duckdb_create_array_type(child : LogicalType, size : Idx) : LogicalType
    fun create_map_type = duckdb_create_map_type(key : LogicalType, value : LogicalType) : LogicalType
    fun create_struct_type = duckdb_create_struct_type(types : LogicalType*, names : LibC::Char**, count : Idx) : LogicalType
    fun create_list_value = duckdb_create_list_value(child : LogicalType, values : Value*, count : Idx) : Value
    fun create_array_value = duckdb_create_array_value(child : LogicalType, values : Value*, count : Idx) : Value
    fun create_struct_value = duckdb_create_struct_value(type : LogicalType, values : Value*) : Value
    fun create_map_value = duckdb_create_map_value(type : LogicalType, keys : Value*, values : Value*, count : Idx) : Value
    fun create_union_value = duckdb_create_union_value(type : LogicalType, tag : Idx, value : Value) : Value
    fun create_null_value = duckdb_create_null_value : Value
    fun create_bool = duckdb_create_bool(value : CBool) : Value
    {% for name in ["Int8", "Int16", "Int32", "Int64", "UInt8", "UInt16", "UInt32", "UInt64"] %}
      fun create_{{name.id.downcase}} = duckdb_create_{{name.id.downcase}}(value : {{name.id}}) : Value
    {% end %}
    fun create_hugeint = duckdb_create_hugeint(value : HugeInt) : Value
    fun create_uhugeint = duckdb_create_uhugeint(value : UHugeInt) : Value
    fun create_float = duckdb_create_float(value : Float32) : Value
    fun create_double = duckdb_create_double(value : Float64) : Value
    fun create_varchar_length = duckdb_create_varchar_length(value : LibC::Char*, size : Idx) : Value
    fun create_blob = duckdb_create_blob(value : UInt8*, size : Idx) : Value
    fun create_date = duckdb_create_date(value : Date) : Value
    fun create_time = duckdb_create_time(value : Time) : Value
    fun create_timestamp = duckdb_create_timestamp(value : Timestamp) : Value
    fun create_interval = duckdb_create_interval(value : Interval) : Value

    # # Memory allocation

    # Allocate [size] amounts of memory using the duckdb internal malloc function. Any memory allocated in this manner
    # should be freed using duckdb_free
    fun malloc = duckdb_malloc(size : LibC::SizeT) : Void*
    # Free memory allocated by DuckDB
    fun free = duckdb_free(ptr : Void*) : Void

    # # Prepared Statements

    fun extract_statements = duckdb_extract_statements(connection : Connection, query : LibC::Char*, out_extracted_statements : ExtractedStatements*) : Idx
    fun extract_statements_error = duckdb_extract_statements_error(extracted_statements : ExtractedStatements) : LibC::Char*
    fun destroy_extracted = duckdb_destroy_extracted(extracted_statements : ExtractedStatements*) : Void

    # prepares the specified SQL query in the specified connection handle. [OUT: prepared statement descriptor]
    fun prepare = duckdb_prepare(connection : Connection, query : LibC::Char*, out_prepared_statement : PreparedStatement*) : State
    fun prepare_error = duckdb_prepare_error(prepared_statement : PreparedStatement) : LibC::Char*
    fun nparams = duckdb_nparams(prepared_statement : PreparedStatement) : Idx
    fun clear_bindings = duckdb_clear_bindings(prepared_statement : PreparedStatement) : State

    # binds parameters to prepared statement
    fun bind_boolean = duckdb_bind_boolean(prepared_statement : PreparedStatement, param_idx : Idx, val : CBool) : State
    fun bind_int8 = duckdb_bind_int8(prepared_statement : PreparedStatement, param_idx : Idx, val : Int8) : State
    fun bind_int16 = duckdb_bind_int16(prepared_statement : PreparedStatement, param_idx : Idx, val : Int16) : State
    fun bind_int32 = duckdb_bind_int32(prepared_statement : PreparedStatement, param_idx : Idx, val : Int32) : State
    fun bind_int64 = duckdb_bind_int64(prepared_statement : PreparedStatement, param_idx : Idx, val : Int64) : State
    fun bind_hugeint = duckdb_bind_hugeint(prepared_statement : PreparedStatement, param_idx : Idx, val : HugeInt) : State
    fun bind_uint8 = duckdb_bind_uint8(prepared_statement : PreparedStatement, param_idx : Idx, val : UInt8) : State
    fun bind_uint16 = duckdb_bind_uint16(prepared_statement : PreparedStatement, param_idx : Idx, val : UInt16) : State
    fun bind_uint32 = duckdb_bind_uint32(prepared_statement : PreparedStatement, param_idx : Idx, val : UInt32) : State
    fun bind_uint64 = duckdb_bind_uint64(prepared_statement : PreparedStatement, param_idx : Idx, val : UInt64) : State
    fun bind_float = duckdb_bind_float(prepared_statement : PreparedStatement, param_idx : Idx, val : Float32) : State
    fun bind_double = duckdb_bind_double(prepared_statement : PreparedStatement, param_idx : Idx, val : Float64) : State
    fun bind_date = duckdb_bind_date(prepared_statement : PreparedStatement, param_idx : Idx, val : Date) : State
    fun bind_time = duckdb_bind_time(prepared_statement : PreparedStatement, param_idx : Idx, val : Time) : State
    fun bind_timestamp = duckdb_bind_timestamp(prepared_statement : PreparedStatement, param_idx : Idx, val : Timestamp) : State
    fun bind_interval = duckdb_bind_interval(prepared_statement : PreparedStatement, param_idx : Idx, val : Interval) : State
    fun bind_varchar = duckdb_bind_varchar(prepared_statement : PreparedStatement, param_idx : Idx, val : LibC::Char*) : State
    fun bind_varchar_length = duckdb_bind_varchar_length(prepared_statement : PreparedStatement, param_idx : Idx, val : LibC::Char*, length : Idx) : State
    fun bind_blob = duckdb_bind_blob(prepared_statement : PreparedStatement, param_idx : Idx, data : Void*, length : Idx) : State
    fun bind_null = duckdb_bind_null(prepared_statement : PreparedStatement, param_idx : Idx) : State

    # Executes the prepared statements with currently bound parameters
    fun execute_prepared = duckdb_execute_prepared(prepared_statement : PreparedStatement, out_result : Result*) : State

    fun execute_prepared_streaming = duckdb_execute_prepared_streaming(prepared_statement : PreparedStatement, out_result : Result*) : State

    # Destroys the specified prepared statement descriptor
    fun destroy_prepare = duckdb_destroy_prepare(prepared_statement : PreparedStatement*) : Void

    # # Appender
    fun appender_create_ext = duckdb_appender_create_ext(connection : Connection, catalog : LibC::Char*, schema : LibC::Char*, table : LibC::Char*, out_appender : Appender*) : State
    fun appender_column_count = duckdb_appender_column_count(appender : Appender) : Idx
    fun appender_column_type = duckdb_appender_column_type(appender : Appender, index : Idx) : LogicalType
    fun appender_error = duckdb_appender_error(appender : Appender) : LibC::Char*
    fun append_uhugeint = duckdb_append_uhugeint(appender : Appender, value : UHugeInt) : State
    fun create_decimal = duckdb_create_decimal(value : Decimal) : Value
    fun appender_create = duckdb_appender_create(connection : Connection, schema : LibC::Char*, table : LibC::Char*, out_appender : Appender*) : State

    fun appender_begin_row = duckdb_appender_begin_row(appender : Appender) : State
    fun appender_end_row = duckdb_appender_end_row(appender : Appender) : State

    fun append_bool = duckdb_append_bool(appender : Appender, value : CBool) : State

    fun append_int8 = duckdb_append_int8(appender : Appender, value : Int8) : State
    fun append_int16 = duckdb_append_int16(appender : Appender, value : Int16) : State
    fun append_int32 = duckdb_append_int32(appender : Appender, value : Int32) : State
    fun append_int64 = duckdb_append_int64(appender : Appender, value : Int64) : State
      
    fun append_hugeint = duckdb_append_hugeint(appender : Appender, value : HugeInt) : State

    fun append_uint8 = duckdb_append_uint8(appender : Appender, value : UInt8) : State
    fun append_uint16 = duckdb_append_uint16(appender : Appender, value : UInt16) : State
    fun append_uint32 = duckdb_append_uint32(appender : Appender, value : UInt32) : State
    fun append_uint64 = duckdb_append_uint64(appender : Appender, value : UInt64) : State

    fun append_float = duckdb_append_float(appender : Appender, value : Float32) : State
    fun append_double = duckdb_append_double(appender : Appender, value : Float64) : State

    fun append_date = duckdb_append_date(appender : Appender, value : Date) : State
    fun append_time = duckdb_append_time(appender : Appender, value : Time) : State
    fun append_timestamp = duckdb_append_timestamp(appender : Appender, value : Timestamp) : State
    fun append_interval = duckdb_append_interval(appender : Appender, value : Interval) : State

    fun append_varchar = duckdb_append_varchar(appender : Appender, val : LibC::Char*) : State
    fun append_varchar_length = duckdb_append_varchar_length(appender : Appender, val : LibC::Char*, length : Idx) : State
    fun append_blob = duckdb_append_blob(appender : Appender, data : Void*, length : Idx) : State
    fun append_null = duckdb_append_null(appender : Appender) : State

    fun appender_flush = duckdb_appender_flush(appender : Appender) : State
    fun appender_close = duckdb_appender_close(appender : Appender) : State

    fun appender_destroy = duckdb_appender_destroy(appender : Appender*) : State
  end
end
