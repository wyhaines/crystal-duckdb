/* Count driver-owned C handles, including handles returned on error. The linker
 * wraps only calls from the spec executable, not DuckDB's internal calls. */
#include <stdint.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <pthread.h>

static _Atomic int64_t results, statements, appenders, open_errors;
static _Atomic int64_t databases, connections, caches;
int64_t spec_live_results(void) { return results; }
int64_t spec_live_statements(void) { return statements; }
int64_t spec_live_appenders(void) { return appenders; }
int64_t spec_live_open_errors(void) { return open_errors; }
int64_t spec_live_databases(void) { return databases; }
int64_t spec_live_connections(void) { return connections; }
int64_t spec_live_caches(void) { return caches; }

/* Several fibers/threads can receive errors before any of them frees one. */
struct open_error { void *ptr; struct open_error *next; };
static struct open_error *errors;
static pthread_mutex_t errors_mutex = PTHREAD_MUTEX_INITIALIZER;
static void track_error(char **error) {
    if (!error || !*error) return;
    struct open_error *entry = malloc(sizeof(*entry));
    entry->ptr = *error;
    pthread_mutex_lock(&errors_mutex);
    entry->next = errors;
    errors = entry;
    open_errors++;
    pthread_mutex_unlock(&errors_mutex);
}

extern int __real_duckdb_open(const char *, void **);
int __wrap_duckdb_open(const char *path, void **db) {
    int state = __real_duckdb_open(path, db);
    if (*db) databases++;
    return state;
}

extern int __real_duckdb_open_ext(const char *, void **, void *, char **);
int __wrap_duckdb_open_ext(const char *path, void **db, void *config, char **error) {
    int state = __real_duckdb_open_ext(path, db, config, error);
    if (*db) databases++;
    track_error(error);
    return state;
}

extern int __real_duckdb_get_or_create_from_cache(void *, const char *, void **, void *, char **);
int __wrap_duckdb_get_or_create_from_cache(void *cache, const char *path, void **db, void *config, char **error) {
    int state = __real_duckdb_get_or_create_from_cache(cache, path, db, config, error);
    if (*db) databases++;
    track_error(error);
    return state;
}

extern void __real_duckdb_close(void **);
void __wrap_duckdb_close(void **db) {
    if (*db) databases--;
    __real_duckdb_close(db);
}

static _Atomic int64_t connect_failure_after = -1;
void spec_fail_connect_after(int64_t count) { connect_failure_after = count; }
extern int __real_duckdb_connect(void *, void **);
int __wrap_duckdb_connect(void *db, void **conn) {
    if (connect_failure_after >= 0 && atomic_fetch_sub(&connect_failure_after, 1) == 0) {
        *conn = 0;
        return 1;
    }
    int state = __real_duckdb_connect(db, conn);
    if (*conn) connections++;
    return state;
}

extern void __real_duckdb_disconnect(void **);
void __wrap_duckdb_disconnect(void **conn) {
    if (*conn) connections--;
    __real_duckdb_disconnect(conn);
}

extern void *__real_duckdb_create_instance_cache(void);
void *__wrap_duckdb_create_instance_cache(void) {
    void *cache = __real_duckdb_create_instance_cache();
    if (cache) caches++;
    return cache;
}

extern void __real_duckdb_destroy_instance_cache(void **);
void __wrap_duckdb_destroy_instance_cache(void **cache) {
    if (*cache) caches--;
    __real_duckdb_destroy_instance_cache(cache);
}

extern void __real_duckdb_free(void *);
void __wrap_duckdb_free(void *ptr) {
    pthread_mutex_lock(&errors_mutex);
    struct open_error **entry = &errors;
    while (*entry) {
        if ((*entry)->ptr == ptr) {
            struct open_error *found = *entry;
            *entry = found->next;
            free(found);
            open_errors--;
            break;
        }
        entry = &(*entry)->next;
    }
    pthread_mutex_unlock(&errors_mutex);
    __real_duckdb_free(ptr);
}

extern int __real_duckdb_query(void *, const char *, void *);
int __wrap_duckdb_query(void *conn, const char *sql, void *result) {
    int state = __real_duckdb_query(conn, sql, result);
    results++;
    return state;
}

extern int __real_duckdb_execute_prepared(void *, void *);
int __wrap_duckdb_execute_prepared(void *stmt, void *result) {
    int state = __real_duckdb_execute_prepared(stmt, result);
    results++;
    return state;
}

extern void __real_duckdb_destroy_result(void *);
void __wrap_duckdb_destroy_result(void *result) {
    results--;
    __real_duckdb_destroy_result(result);
}

extern int __real_duckdb_prepare(void *, const char *, void **);
int __wrap_duckdb_prepare(void *conn, const char *sql, void **stmt) {
    int state = __real_duckdb_prepare(conn, sql, stmt);
    if (*stmt) statements++;
    return state;
}

extern void __real_duckdb_destroy_prepare(void **);
void __wrap_duckdb_destroy_prepare(void **stmt) {
    if (*stmt) statements--;
    __real_duckdb_destroy_prepare(stmt);
}

extern int __real_duckdb_appender_create(void *, const char *, const char *, void **);
int __wrap_duckdb_appender_create(void *conn, const char *schema, const char *table, void **appender) {
    int state = __real_duckdb_appender_create(conn, schema, table, appender);
    if (*appender) appenders++;
    return state;
}

extern int __real_duckdb_appender_destroy(void **);
int __wrap_duckdb_appender_destroy(void **appender) {
    if (*appender) appenders--;
    return __real_duckdb_appender_destroy(appender);
}

/* Match the public duckdb_result layout: fetch_chunk passes all 48 bytes by
 * value, rather than passing the address as the other result functions do. */
typedef struct {
    uint64_t columns_count, rows_count, changed;
    void *columns;
    char *error;
    void *internal;
} spec_result;
static _Atomic int64_t chunks, logical_types, streaming_executions, fetched_chunks, acquired_types;
int64_t spec_live_chunks(void) { return chunks; }
int64_t spec_live_logical_types(void) { return logical_types; }
int64_t spec_streaming_executions(void) { return streaming_executions; }
int64_t spec_fetched_chunks(void) { return fetched_chunks; }
int64_t spec_acquired_types(void) { return acquired_types; }

extern int __real_duckdb_execute_prepared_streaming(void *, void *);
int __wrap_duckdb_execute_prepared_streaming(void *stmt, void *result) {
    int state = __real_duckdb_execute_prepared_streaming(stmt, result);
    results++;
    streaming_executions++;
    return state;
}

extern void *__real_duckdb_fetch_chunk(spec_result);
void *__wrap_duckdb_fetch_chunk(spec_result result) {
    void *chunk = __real_duckdb_fetch_chunk(result);
    if (chunk) { chunks++; fetched_chunks++; }
    return chunk;
}
extern void __real_duckdb_destroy_data_chunk(void **);
void __wrap_duckdb_destroy_data_chunk(void **chunk) {
    if (*chunk) chunks--;
    __real_duckdb_destroy_data_chunk(chunk);
}

#define TYPE_WRAPPER(name) \
    extern void *__real_##name(void *); \
    void *__wrap_##name(void *parent) { \
        void *type = __real_##name(parent); \
        if (type) { logical_types++; acquired_types++; } \
        return type; \
    }
#define INDEXED_TYPE_WRAPPER(name) \
    extern void *__real_##name(void *, uint64_t); \
    void *__wrap_##name(void *parent, uint64_t index) { \
        void *type = __real_##name(parent, index); \
        if (type) { logical_types++; acquired_types++; } \
        return type; \
    }
INDEXED_TYPE_WRAPPER(duckdb_column_logical_type)
INDEXED_TYPE_WRAPPER(duckdb_struct_type_child_type)
INDEXED_TYPE_WRAPPER(duckdb_union_type_member_type)
TYPE_WRAPPER(duckdb_vector_get_column_type)
TYPE_WRAPPER(duckdb_list_type_child_type)
TYPE_WRAPPER(duckdb_array_type_child_type)
TYPE_WRAPPER(duckdb_map_type_key_type)
TYPE_WRAPPER(duckdb_map_type_value_type)
extern void __real_duckdb_destroy_logical_type(void **);
void __wrap_duckdb_destroy_logical_type(void **type) {
    if (*type) logical_types--;
    __real_duckdb_destroy_logical_type(type);
}

static _Atomic int64_t extracted_statements;
int64_t spec_live_extracted_statements(void) { return extracted_statements; }

extern uint64_t __real_duckdb_extract_statements(void *, const char *, void **);
uint64_t __wrap_duckdb_extract_statements(void *conn, const char *sql, void **extracted) {
    uint64_t count = __real_duckdb_extract_statements(conn, sql, extracted);
    if (*extracted) extracted_statements++;
    return count;
}

extern void __real_duckdb_destroy_extracted(void **);
void __wrap_duckdb_destroy_extracted(void **extracted) {
    if (*extracted) extracted_statements--;
    __real_duckdb_destroy_extracted(extracted);
}

/* Values used for exact parameter binding, plus dictionary allocation counts. */
static _Atomic int64_t owned_values, enum_dictionary_reads;
int64_t spec_live_values(void) { return owned_values; }
int64_t spec_enum_dictionary_reads(void) { return enum_dictionary_reads; }
#define VALUE_WRAPPER(name, type) \
    extern void *__real_##name(type); \
    void *__wrap_##name(type input) { \
        void *value = __real_##name(input); \
        if (value) owned_values++; \
        return value; \
    }
typedef struct { uint64_t lower, upper; } spec_uhugeint;
typedef struct { int64_t count; } spec_temporal;
typedef struct { void *data; uint64_t size; uint8_t is_negative; } spec_bignum;
VALUE_WRAPPER(duckdb_create_uuid, spec_uhugeint)
VALUE_WRAPPER(duckdb_create_bignum, spec_bignum)
VALUE_WRAPPER(duckdb_create_time_ns, spec_temporal)
VALUE_WRAPPER(duckdb_create_time_tz_value, spec_temporal)
VALUE_WRAPPER(duckdb_create_timestamp_s, spec_temporal)
VALUE_WRAPPER(duckdb_create_timestamp_ms, spec_temporal)
VALUE_WRAPPER(duckdb_create_timestamp_ns, spec_temporal)
VALUE_WRAPPER(duckdb_create_timestamp_tz, spec_temporal)
extern void __real_duckdb_destroy_value(void **);
void __wrap_duckdb_destroy_value(void **value) {
    if (*value) owned_values--;
    __real_duckdb_destroy_value(value);
}
extern char *__real_duckdb_enum_dictionary_value(void *, uint64_t);
char *__wrap_duckdb_enum_dictionary_value(void *type, uint64_t index) {
    enum_dictionary_reads++;
    return __real_duckdb_enum_dictionary_value(type, index);
}

extern int __real_duckdb_appender_create_ext(void *, const char *, const char *, const char *, void **);
int __wrap_duckdb_appender_create_ext(void *conn, const char *catalog, const char *schema, const char *table, void **appender) {
    int state = __real_duckdb_appender_create_ext(conn, catalog, schema, table, appender);
    if (*appender) appenders++;
    return state;
}
INDEXED_TYPE_WRAPPER(duckdb_appender_column_type)
typedef struct { uint8_t width, scale; spec_uhugeint value; } spec_decimal;
VALUE_WRAPPER(duckdb_create_decimal, spec_decimal)
