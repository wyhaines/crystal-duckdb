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
