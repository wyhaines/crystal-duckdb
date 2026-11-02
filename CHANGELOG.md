# Changelog

All notable changes to this shard are documented here, following [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- macOS arm64 CI for DuckDB 1.5.6 and 2.0.0 with the latest Crystal, including the README programs and the four-worker execution-context specs. `scripts/ci-local.sh` and `scripts/check-readme.sh` run on macOS: they verify the pinned official archive and find `libduckdb.dylib` through an rpath, because SIP strips `DYLD_*` variables.
- `Appender#append_columns(*columns)` loads column-oriented data: one `Indexable` per destination column, equal lengths, `nil` for NULL. Element types must be writable exactly; column count, lengths and element types are checked before anything is appended.
- The spec suite's native-handle counters are optional. They need GNU ld `--wrap`, so they run on Linux only; elsewhere, or with `-Dno_native_lifetime`, the counter assertions are reported as pending and the other specs still run.

### Changed

- The Appender buffers rows in a DuckDB data chunk and submits it with `duckdb_append_data_chunk`. Values that match their column, or widen into it without loss, are written directly; everything else still uses DuckDB's conversion, with row order, errors at `<<`, and flush/discard behaviour unchanged. On a loaded laptop, 500,000-row appends went from 14–16 to 23–24 M rows/s for BIGINT and from 5–7 to 20–26 M rows/s for DECIMAL(18,3).
- On DuckDB 2.0, the Appender writes sub-microsecond TZ Timestamps exactly into TIMESTAMP_TZ_NS columns (previously they raised).

## [0.3.0] - Unreleased

### Breaking

- Support targets DuckDB 1.5.x and 2.0.x. Older engines, including 1.4.x, are not officially supported. The minimum Crystal version is now 1.9.0; crystal-db must be `>= 0.13.1, < 0.16.0`.
- Untyped reads return exact values instead of the old String fallback: DECIMAL becomes `DuckDB::Decimal`, UUID becomes `UUID`, UHUGEINT becomes `UInt128`, LIST/ARRAY become arrays, STRUCT/MAP become hashes, UNION returns its active member, timestamp variants become `DuckDB::Timestamp`, TIME_TZ becomes `DuckDB::TimeTZ`, BIT becomes a bit string, BIGNUM becomes `DuckDB::BigNum`, and GEOMETRY becomes WKB bytes. Use `DuckDB::Value` for recursive results; `DuckDB::Any` describes scalar parameters. Non-NULL VARIANT reads raise `DuckDB::Exception`; cast to a supported SQL type.
- Date text preserves small years, BC dates, and infinities. Date and Timestamp conversion to Crystal Time raises `DuckDB::Exception` for infinity or years outside 1–9999. Calendar getters raise on infinity; Timestamp's `date` raises outside the DATE range.
- TimeOfDay stores nanoseconds, preserves Time/Time::Span precision, and accepts SQL `24:00:00`. Invalid fields and negative or day-long spans raise `ArgumentError`. The existing Int64 and fourth field constructor arguments remain microseconds.
- Timestamp stores nanoseconds with explicit infinity and timezone state; `year` returns `Int64`. `microseconds` raises when a finite value cannot be represented exactly as Int64 microseconds. The existing Int64 constructor still takes microseconds. TZ text is normalized to UTC with `+00`, independent of the SQL display timezone.
- Binding UTC Time and temporal wrappers preserves submicrosecond input precision instead of truncating in Crystal. Unsupported native representations raise. Non-microsecond TZ Timestamp binding and appending raise on both supported engines because the required constructor is absent from the common C API. Subsequent SQL casts follow DuckDB's rules.
- Appender table names are literal identifiers. Replace `appender("schema.table")` with `appender("table", schema: "schema")`; pass `catalog:` separately. Do not SQL-quote these arguments. The connection method's named table argument is now `table:` (formerly `table_name:`).
- Appending Decimal or exact temporal wrappers raises when a destination discards fractional digits; Decimal-to-float appends also raise. Stdlib UTC Time uses DuckDB's destination cast, which can round, truncate, or reject a conversion depending on engine and destination type.
- SQL text and Appender table/schema/catalog names containing NUL bytes raise `DuckDB::Exception` instead of silently truncating. String parameter, Appender, and result values preserve embedded NUL bytes.
- Prepared statements require the exact argument count on every execution and clear previous bindings. Unprepared queries reject bound arguments. Operations on closed results, and reads from unpositioned results or beyond the last column, raise `DuckDB::Exception`.
- Connections in one pool now share a database, including anonymous memory pools. Separate opens of the same normalized file or named memory database share an instance and committed writes; incompatible simultaneous configurations raise. Anonymous memory URIs now create memory databases rather than a file named `[:memory:]`.
- `DB::ExecResult#last_insert_id` is now zero rather than the affected-row count. Use SQL `RETURNING` for generated IDs.
- The incorrect `LibDuckDB::Type::JSON` member is removed; enum value 28 is UNION. Low-level `duckdb_value_*` bindings and ResultSet reader macros are removed.

### Added

- Execution-context concurrency and blocking specs, with usage guidance for parallel fibers and long analytical queries.
- Opt-in streaming through the `stream_results` URI option and connection property. Unprepared single-statement SQL uses the streaming path; multiple statements and exec remain materialized. One active stream per connection is enforced: another prepare/query/exec raises without invalidating the original stream, even after changing the property. Exhausting or closing it releases the guard. Fetch-time errors propagate during iteration.
- Block-scoped `Connection#each_chunk` and `PooledDatabase#each_chunk`, with bound arguments and an explicit per-call streaming override. Chunks expose row count, column metadata, typed vectors, nested traversal, and owned recursive values. Expired views raise; `with_string_bytes` and `with_bytes` borrow buffers only inside callbacks and keep them alive through callback exit.
- Exact Decimal values through width 38, UUID, UInt128, BigNum, TimeTZ, nanosecond time, and every timestamp resolution, plus nullable and recursive typed reads. `read(String)` retains scalar formatting compatibility, `read(Time)` supports DATE and all timestamps, and Array/Hash reads recursively convert supported elements.
- Exact scalar parameter bindings and Appender support for Decimal, UUID, UInt128, BigNum, TimeTZ, and temporal resolution variants. Extended Appender creation accepts separate literal table, schema, and catalog arguments; `closed?` exposes its state. Nested arrays/hashes remain read-only values.
- `Timestamp#to_span` returns the exact duration since the Unix epoch, with range and infinity checks. `Connection#driver_name` identifies the driver as `duckdb` for current crystal-db APIs.
- Optional `require "duckdb/big"` for Decimal-to-BigDecimal and BigNum-to-BigInt conversions; ordinary reads and formatting do not require GMP.
- Linux CI over DuckDB 1.5.6/2.0.0 and minimum/latest Crystal, with specs and README programs checked in every cell, digest-checked official library downloads, manual workflow dispatch, and `scripts/ci-local.sh` for local reproduction.
- Regression specs with native-handle counters, release/read/chunk/Appender/leak benchmarks, maintained read-breakdown and streaming-memory programs, a README program checker, and a shard/runtime version consistency spec.

### Changed

- ResultSet reads use data chunks and vectors with one cached logical-type tree per result and no scalar C API call per value. Typed reads avoid the recursive result union on scalar paths. Strings and blobs are copied before chunk destruction; public callbacks offer borrowed bytes.
- Queries remain materialized by default. A cached prepared statement can be re-executed while its earlier materialized results remain open. A pool holds the connection until all its results close; explicit statement and connection close also close their results.
- Pool database ownership persists even when there are no checked-out or idle connections. A process-wide, mutex-protected instance cache coordinates file and named-memory opens. Closing the last user releases the instance for reopening with different settings.
- Appenders close deterministically, flush and destroy native handles even on failure, close on every block exit, and close before their connection disconnects. Repeated close is safe and later use raises.
- HUGEINT conversions use integer shifts and casts instead of allocating and serializing through IO::Memory. Decimal and temporal reads/bindings avoid floating-point intermediates.
- URI option filtering separates crystal-db options (including `prepared_statements_cache`) and `stream_results` from DuckDB settings. Other query parameters still configure DuckDB; the README now requires trusted connection URIs and explains the security implications.
- Compatibility, installation, pooling, types, temporal semantics, measured performance, platform limitations, and contributor attribution are documented for this fork. The shard name remains `duckdb`; Kirk Haines is added as an author after creator Amaury Trujillo.

### Fixed

- In-memory URI parsing no longer creates `[:memory:]` files, resolving upstream [PR #4](https://github.com/amauryt/crystal-duckdb/pull/4). Literal plus signs in file paths survive URI decoding, including named-memory URI handling.
- The dependency constraint permits crystal-db 0.13.1–0.15.x instead of forcing other drivers onto older versions, resolving upstream [issue #5](https://github.com/amauryt/crystal-duckdb/issues/5). Unprepared result creation uses the native DuckDB connection, resolving upstream [issue #6](https://github.com/amauryt/crystal-duckdb/issues/6).
- Independent database instances no longer hide or lose committed writes to the same file; pools and standalone connections share the appropriate native database owner.
- Races under parallel execution contexts: a growing pool could hand one new connection to two fibers (a crystal-db 0.13.1–0.15.0 pool defect, worked around in pools created by `DB.open`); closing a connection, statement or failed stream could return the connection to the pool before cleanup finished, or release it twice; an open appender did not keep its pool checkout; a connection could be built against a database owner that was closing concurrently; and setup callbacks could lose their connection.
- Closing the last file or named-memory database reliably destroys the instance cache. The C destructor receives a local handle to avoid class-variable reinitialization leaking the live cache.
- Native results, prepared statements, chunks, logical types (including nested types), configuration/open error strings, Appender handles, and temporary binding values are released on success, early exit, close, and error paths. ResultSet initialization and close now participate in crystal-db ownership, preventing exhausted one-connection pools and uncached-statement leaks.
- Prepare and unprepared-exec failures are checked and raised. Binding failures without a native error string get a useful driver error instead of an unrelated null-pointer exception. Reused statements cannot silently retain omitted arguments.
- NULL and SQLNULL reads work on DuckDB 2.0, including mixed result columns. Embedded NUL bytes survive bound/appended/returned strings, with length-aware access rather than C-string truncation.
- Closed and invalid cursor reads cannot reach freed native state. Row and chunk counters use Int64, avoiding the previous Int32 scan limit.
- Finite timestamps before and after the former nanosecond-span range, dates outside Crystal Time's range, and infinite temporal values retain their exact engine values. Integer conversion avoids timestamp microsecond rounding and overflow. TimeOfDay validates all fields and reads end-of-day TIME values.
- Appender identifiers containing dots, quotes, or reserved words work as literal names. UTC `Time.utc` values with submicrosecond precision append through an exact native value before DuckDB's destination cast; wrappers enforce destination precision explicitly.
- C declarations match the supported headers, including the corrected `duckdb_nparams` return type and argument list, type IDs through 42, and length-aware string ABI. Returned strings and blobs remain owned after their chunk is destroyed.

### Removed

- The catch-all conversion of unrecognized SQL types to String. Unsupported non-NULL types now report their column and type.
- Scalar `duckdb_value_*` reads, per-value type lookups, result-row-count polling, the incorrect JSON C type member, and the Appender GC finalizer in favor of deterministic ownership.
- The macOS-only Homebrew CI job and its invalid spec command. CI and the native-handle wrapper specs currently run on Linux; Windows and macOS are not validated by CI.

## [0.2.5]

The last upstream release covered DuckDB 0.9.x–1.3.x and crystal-db 0.13. See the [upstream release](https://github.com/amauryt/crystal-duckdb/releases/tag/v0.2.5) and [upstream history](https://github.com/amauryt/crystal-duckdb/commits/master/).

[Unreleased]: https://github.com/wyhaines/crystal-duckdb/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/wyhaines/crystal-duckdb/compare/1adee51...v0.3.0
[0.2.5]: https://github.com/amauryt/crystal-duckdb/releases/tag/v0.2.5
