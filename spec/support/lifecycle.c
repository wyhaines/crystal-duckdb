/* Count driver-owned C handles, including handles returned on error. The linker
 * wraps only calls from the spec executable, not DuckDB's internal calls. */
#include <stdint.h>

static int64_t results, statements, appenders, open_errors;
static void *open_error;
int64_t spec_live_results(void) { return results; }
int64_t spec_live_statements(void) { return statements; }
int64_t spec_live_appenders(void) { return appenders; }
int64_t spec_live_open_errors(void) { return open_errors; }

extern int __real_duckdb_open_ext(const char *, void **, void *, char **);
int __wrap_duckdb_open_ext(const char *path, void **db, void *config, char **error) {
    int state = __real_duckdb_open_ext(path, db, config, error);
    if (*error) {
        open_errors++;
        open_error = *error;
    }
    return state;
}

extern void __real_duckdb_free(void *);
void __wrap_duckdb_free(void *ptr) {
    if (ptr && ptr == open_error) {
        open_errors--;
        open_error = 0;
    }
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
