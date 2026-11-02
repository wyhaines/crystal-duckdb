#define _GNU_SOURCE
#include <dlfcn.h>
#include <string.h>
/* Count driver-owned C handles, including handles returned on error. The linker
 * wraps only calls from the spec executable, not DuckDB's internal calls. */
#include <stdint.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <pthread.h>

static _Atomic int64_t results, statements, appenders, open_errors, preparations;
int64_t spec_preparations(void) { return preparations; }
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
    preparations++;
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
static _Atomic int64_t value_failure_after = -1, type_failure_after = -1;
void spec_fail_value_after(int64_t n) { value_failure_after = n; }
void spec_fail_type_after(int64_t n) { type_failure_after = n; }
static int constructor_failure(int is_value) {
    _Atomic int64_t *counter = is_value ? &value_failure_after : &type_failure_after;
    return *counter >= 0 && atomic_fetch_sub(counter, 1) == 0;
}
#define VALUE_WRAPPER(name, type) \
    extern void *__real_##name(type); \
    void *__wrap_##name(type input) { \
        if (constructor_failure(1)) return NULL; \
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

static _Atomic int64_t created_chunks, appended_chunks, chunk_failure_after = -1;
int64_t spec_created_chunks(void) { return created_chunks; }
int64_t spec_appended_chunks(void) { return appended_chunks; }
void spec_fail_create_chunk_after(int64_t count) { chunk_failure_after = count; }
extern void *__real_duckdb_create_data_chunk(void **, uint64_t);
void *__wrap_duckdb_create_data_chunk(void **types, uint64_t count) {
    if (chunk_failure_after >= 0 && atomic_fetch_sub(&chunk_failure_after, 1) == 0) return NULL;
    void *chunk = __real_duckdb_create_data_chunk(types, count);
    if (chunk) { chunks++; created_chunks++; }
    return chunk;
}
extern int __real_duckdb_append_data_chunk(void *, void *);
int __wrap_duckdb_append_data_chunk(void *appender, void *chunk) {
    appended_chunks++;
    return __real_duckdb_append_data_chunk(appender, chunk);
}

/* Nested construction, including all scalar leaves and inferred logical types. */
INDEXED_TYPE_WRAPPER(duckdb_param_logical_type)
VALUE_WRAPPER(duckdb_create_bool, uint8_t)
VALUE_WRAPPER(duckdb_create_int8, int8_t)
VALUE_WRAPPER(duckdb_create_int16, int16_t)
VALUE_WRAPPER(duckdb_create_int32, int32_t)
VALUE_WRAPPER(duckdb_create_int64, int64_t)
VALUE_WRAPPER(duckdb_create_uint8, uint8_t)
VALUE_WRAPPER(duckdb_create_uint16, uint16_t)
VALUE_WRAPPER(duckdb_create_uint32, uint32_t)
VALUE_WRAPPER(duckdb_create_uint64, uint64_t)
VALUE_WRAPPER(duckdb_create_hugeint, spec_uhugeint)
VALUE_WRAPPER(duckdb_create_uhugeint, spec_uhugeint)
VALUE_WRAPPER(duckdb_create_float, float)
VALUE_WRAPPER(duckdb_create_double, double)
typedef struct { int32_t days; } spec_date;
typedef struct { int32_t months, days; int64_t micros; } spec_interval;
VALUE_WRAPPER(duckdb_create_date, spec_date)
VALUE_WRAPPER(duckdb_create_time, spec_temporal)
VALUE_WRAPPER(duckdb_create_timestamp, spec_temporal)
VALUE_WRAPPER(duckdb_create_interval, spec_interval)

#define CONSTRUCTOR_WRAPPER(name, counter, params, args) \
    extern void *__real_##name params; \
    void *__wrap_##name params { \
        if (constructor_failure(&counter == &owned_values)) return NULL; \
        void *handle = __real_##name args; \
        if (handle) counter++; \
        return handle; \
    }
CONSTRUCTOR_WRAPPER(duckdb_create_null_value, owned_values, (void), ())
CONSTRUCTOR_WRAPPER(duckdb_create_varchar_length, owned_values, (const char *s, uint64_t n), (s, n))
CONSTRUCTOR_WRAPPER(duckdb_create_blob, owned_values, (const uint8_t *s, uint64_t n), (s, n))
CONSTRUCTOR_WRAPPER(duckdb_create_list_value, owned_values, (void *t, void **v, uint64_t n), (t, v, n))
CONSTRUCTOR_WRAPPER(duckdb_create_array_value, owned_values, (void *t, void **v, uint64_t n), (t, v, n))
CONSTRUCTOR_WRAPPER(duckdb_create_struct_value, owned_values, (void *t, void **v), (t, v))
CONSTRUCTOR_WRAPPER(duckdb_create_map_value, owned_values, (void *t, void **k, void **v, uint64_t n), (t, k, v, n))
CONSTRUCTOR_WRAPPER(duckdb_create_union_value, owned_values, (void *t, uint64_t tag, void *v), (t, tag, v))
CONSTRUCTOR_WRAPPER(duckdb_create_logical_type, logical_types, (int t), (t))
CONSTRUCTOR_WRAPPER(duckdb_create_list_type, logical_types, (void *t), (t))
CONSTRUCTOR_WRAPPER(duckdb_create_array_type, logical_types, (void *t, uint64_t n), (t, n))
CONSTRUCTOR_WRAPPER(duckdb_create_map_type, logical_types, (void *k, void *v), (k, v))
CONSTRUCTOR_WRAPPER(duckdb_create_struct_type, logical_types, (void **t, const char **names, uint64_t n), (t, names, n))

/* --wrap cannot intercept calls through a pointer obtained by dlsym. Wrap the
 * lookup and substitute a counting trampoline, with no reference to a 2.0-only
 * symbol in the executable. The driver's mutex serializes lookup/publication. */
static void *(*tz_ns_constructor)(spec_temporal);
static _Atomic int64_t tz_ns_lookups;
int64_t spec_tz_ns_lookups(void) { return tz_ns_lookups; }
static void *counted_tz_ns(spec_temporal input) {
    if (constructor_failure(1)) return NULL;
    void *value = tz_ns_constructor(input);
    if (value) owned_values++;
    return value;
}
extern void *__real_dlsym(void *, const char *);
void *__wrap_dlsym(void *handle, const char *name) {
    void *symbol = __real_dlsym(handle, name);
    if (strcmp(name, "duckdb_create_timestamp_tz_ns") == 0) {
        tz_ns_lookups++;
        if (symbol) { tz_ns_constructor = symbol; return counted_tz_ns; }
    }
    return symbol;
}

/* Exercise root-value cleanup when the bind/append API itself rejects it. */
static _Atomic int fail_bind_value, fail_append_value;
void spec_fail_bind_value(int fail) { fail_bind_value = fail; }
void spec_fail_append_value(int fail) { fail_append_value = fail; }
extern int __real_duckdb_bind_value(void *, uint64_t, void *);
int __wrap_duckdb_bind_value(void *stmt, uint64_t index, void *value) {
    if (atomic_exchange(&fail_bind_value, 0)) return 1;
    return __real_duckdb_bind_value(stmt, index, value);
}
extern int __real_duckdb_append_value(void *, void *);
int __wrap_duckdb_append_value(void *appender, void *value) {
    if (atomic_exchange(&fail_append_value, 0)) return 1;
    return __real_duckdb_append_value(appender, value);
}

static _Atomic int64_t timestamp_binds, time_binds, decimal_binds;
int64_t spec_timestamp_binds(void) { return timestamp_binds; }
int64_t spec_time_binds(void) { return time_binds; }
int64_t spec_decimal_binds(void) { return decimal_binds; }
extern int __real_duckdb_bind_timestamp(void *, uint64_t, spec_temporal);
int __wrap_duckdb_bind_timestamp(void *stmt, uint64_t index, spec_temporal value) {
    timestamp_binds++;
    return __real_duckdb_bind_timestamp(stmt, index, value);
}
extern int __real_duckdb_bind_time(void *, uint64_t, spec_temporal);
int __wrap_duckdb_bind_time(void *stmt, uint64_t index, spec_temporal value) {
    time_binds++;
    return __real_duckdb_bind_time(stmt, index, value);
}
extern int __real_duckdb_bind_decimal(void *, uint64_t, spec_decimal);
int __wrap_duckdb_bind_decimal(void *stmt, uint64_t index, spec_decimal value) {
    decimal_binds++;
    return __real_duckdb_bind_decimal(stmt, index, value);
}
