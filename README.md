# crystal-duckdb

[![Crystal CI](https://github.com/wyhaines/crystal-duckdb/actions/workflows/crystal.yml/badge.svg)](https://github.com/wyhaines/crystal-duckdb/actions/workflows/crystal.yml)

A [crystal-db](https://github.com/crystal-lang/crystal-db) driver for [DuckDB](https://duckdb.org/), an embedded analytical SQL database. Amaury Trujillo created the shard; Kirk Haines maintains this fork.

## Project status

This is an actively maintained fork of [amauryt/crystal-duckdb](https://github.com/amauryt/crystal-duckdb), where upstream development has been quiet since July 2025. Release 0.3.0 replaces scalar C API reads with chunk and vector reads, adds optional streaming, and returns exact scalar and nested values. It has breaking changes; see [CHANGELOG.md](CHANGELOG.md) before upgrading.

## Compatibility

| Component | Supported versions |
| --- | --- |
| DuckDB | 1.5.x and 2.0.x; Linux CI tests 1.5.6 and 2.0.0 |
| crystal-db | 0.13.1–0.15.x (`>= 0.13.1, < 0.16.0`) |
| Crystal | ≥ 1.9.0; CI tests the minimum and latest release |

Historical shard/engine compatibility:

| Shard release | DuckDB engine | Notes |
| --- | --- | --- |
| 0.3.0 | 1.5.x, 2.0.x | Exact types, chunk reads, streaming; breaking API changes. |
| 0.2.5 | 0.9.x–1.3.x | Storage compatibility. Updated crystal-db to 0.13. |
| 0.2.4 | 0.9.x–0.10.x | Storage incompatibility. Updated crystal-db to 0.12. |
| 0.2.3 | 0.6.0–0.8.x | Added HUGEINT support; changed VARCHAR C API. |
| 0.2.2 | 0.5.1–0.6.0 | Added INTERVAL and configuration support. |
| 0.2.1 | 0.3.4–0.5.1 | Storage incompatibility. Updated crystal-db to 0.11. |
| 0.2.0 | 0.2.9–0.3.2 | Storage incompatibility. |
| 0.1.x | 0.2.8 | |

For databases from older engines, consult DuckDB's [export/import documentation](https://duckdb.org/docs/stable/sql/statements/export) before changing engine versions.

## Prerequisites

Install the official DuckDB **C shared library**, including `libduckdb.so` on Linux or `libduckdb.dylib` on macOS. The command-line executable alone is insufficient. Get the archive for your operating system and architecture from the [official releases](https://github.com/duckdb/duckdb/releases).

For Linux amd64, the archive names differ by release:

```sh
# DuckDB 1.5.6
curl -fLO https://github.com/duckdb/duckdb/releases/download/v1.5.6/libduckdb-linux-amd64.zip
unzip libduckdb-linux-amd64.zip -d duckdb-1.5.6

# DuckDB 2.0.0
curl -fLO https://github.com/duckdb/duckdb/releases/download/v2.0.0/duckdb-shared-libs-linux-amd64.tar.gz
mkdir -p duckdb-2.0.0
tar -xzf duckdb-shared-libs-linux-amd64.tar.gz -C duckdb-2.0.0
```

Alternatively, Homebrew supplies the library:

```sh
brew install duckdb
export LIBRARY_PATH="$(brew --prefix duckdb)/lib${LIBRARY_PATH:+:$LIBRARY_PATH}"
```

Check that the installed engine is in the supported range. For a manually extracted Linux library, set both the link-time and runtime search paths, using the same directory for compilation and execution:

```sh
export LIBRARY_PATH="$PWD/duckdb-2.0.0${LIBRARY_PATH:+:$LIBRARY_PATH}"
export LD_LIBRARY_PATH="$PWD/duckdb-2.0.0${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
```

On macOS, use `DYLD_LIBRARY_PATH` for the runtime path if the library is outside the loader's default search paths. The optional `duckdb/big` conversions also need GMP (`libgmp-dev` on Debian/Ubuntu, `brew install gmp` on macOS).

## Installation

Add this dependency to `shard.yml`, then run `shards install`:

```yaml
dependencies:
  duckdb:
    github: wyhaines/crystal-duckdb
    version: ~> 0.3.0
```

The shard name remains `duckdb`. Existing users switch forks by changing only the `github:` line; keep the dependency name and `require "duckdb"`. Update an older version constraint to the one above when upgrading to 0.3.0.

## Usage

### Connect and query

Use `DB.connect` for one connection or `DB.open` for a pool. Block forms close their resources on exit. These examples use memory databases; a file URI such as `duckdb://./data.db` creates or opens a persistent database.

```crystal
require "duckdb"

DB.connect DuckDB::IN_MEMORY do |cnn|
  cnn.exec "CREATE TABLE contacts (name VARCHAR, age INTEGER)"
  cnn.exec "INSERT INTO contacts VALUES (?, ?)", "John Doe", 30
  cnn.exec "INSERT INTO contacts VALUES (?, ?)", "Sarah", 33

  puts cnn.scalar("SELECT max(age) FROM contacts") # => 33
  cnn.query "SELECT name, age FROM contacts ORDER BY age DESC" do |rs|
    rs.each do
      puts "#{rs.read(String)} (#{rs.read(Int32)})"
      # Sarah (33), then John Doe (30)
    end
  end
end
```

Bind values with `?` placeholders. Each execution requires exactly the statement's argument count and clears previous bindings. Unprepared queries accept no bound arguments. `exec` returns an affected-row count and `last_insert_id = 0`; use SQL `RETURNING` to obtain generated IDs.

### Database instances and pools

All connections in a `DB.open` pool share one DuckDB database, even if the pool temporarily has no connections. Close the pool to release its database. A standalone `DB.connect` releases its database when the connection closes.

File databases use DuckDB's process-wide instance cache, so separate pools and standalone connections opening the same normalized file path share committed writes. DuckDB rejects incompatible configurations for an already open database; the driver raises `DuckDB::Exception` with DuckDB's message. After the last user closes, the file is released and can be reopened with different settings.

Cache and owner operations are protected by mutexes for concurrent connection creation. Use a separate connection for each concurrent query. Materialized results can remain open while the same connection runs another query, including re-executing a cached statement. A pool retains the checked-out connection until all its results close.

```crystal
require "duckdb"

DB.open "#{DuckDB::IN_MEMORY}?max_pool_size=2" do |db|
  db.using_connection do |first|
    first.exec "CREATE TABLE shared_values AS SELECT 42::BIGINT AS n"
    db.using_connection do |second|
      puts second.scalar("SELECT n FROM shared_values") # => 42
    end
  end
end
```

### Concurrency and execution contexts

Use a connection, and its results, streams and appenders, from one fiber at a time. Use a pool (`DB.open`), or one connection per fiber, for parallel work. Fibers may migrate between OS threads while holding these resources; sequential use is supported. Finish worker fibers before closing their pool.

On Crystal 1.21 and later, execution contexts provide parallelism. The default context starts with parallelism 1; `Fiber::ExecutionContext.default.resize(4)` allows more fibers to run in parallel. DuckDB C calls block their calling OS thread and do not yield to Crystal's scheduler. Resizing alone did not reliably keep timers responsive in local measurements, so run long analytical queries in `Fiber::ExecutionContext::Isolated.new("analytics") { ... }` and wait with `join` when needed. DuckDB's own `threads` setting controls its query workers separately from Crystal's execution-context threads.

### In-memory databases

`DuckDB::IN_MEMORY`, `duckdb://`, and `duckdb::memory:` open anonymous memory databases. Each standalone connection or pool gets its own database. For shared named memory, use `duckdb::memory:my_name` or `duckdb://%3Amemory%3Amy_name`. A name shares an instance across pools and standalone connections until its last user closes.

```crystal
require "duckdb"

DB.connect "duckdb::memory:readme_shared" do |first|
  first.exec "CREATE TABLE messages AS SELECT 'hello' AS text"
  DB.connect "duckdb::memory:readme_shared" do |second|
    puts second.scalar("SELECT text FROM messages") # => hello
  end
end
```

### Configuration

Pass DuckDB settings and crystal-db pool options in the URI. Invalid engine settings raise `DuckDB::Exception`. For a file that already exists, `access_mode=read_only` opens it read-only. See the [DuckDB configuration reference](https://duckdb.org/docs/stable/configuration/overview).

**Security note:** every URI query parameter that is not a crystal-db option becomes a DuckDB setting, except the driver's `stream_results` option. This includes settings such as `allow_unsigned_extensions` and `enable_external_access`. Connection URIs must come from trusted configuration. If accepting user-supplied options, apply an explicit allow-list; configuration filtering does not sandbox SQL.

```crystal
require "duckdb"

DB.connect "duckdb::memory:?threads=4&default_null_order=nulls_last" do |cnn|
  puts cnn.scalar("SELECT current_setting('threads')")            # => 4
  puts cnn.scalar("SELECT current_setting('default_null_order')") # => NULLS_LAST
end
```

### Streaming

Queries materialize their results by default. Opt in with `stream_results=true` in a URI, or set `connection.as(DuckDB::Connection).stream_results = true` for subsequent queries. `exec` always materializes so affected-row counts are final. Unprepared queries stream only when the SQL contains one statement; multiple statements keep the materialized path.

```crystal
require "duckdb"

DB.connect "duckdb::memory:?stream_results=true" do |cnn|
  cnn.query "SELECT i::BIGINT FROM range(10) AS t(i)" do |rs|
    rs.each { puts rs.read(Int64) }
  end
  puts cnn.scalar("SELECT 42") # The previous stream is closed.
end
```

Only one active stream is allowed per connection. Preparing or executing another query while a stream is active raises `DuckDB::Exception`. The original stream remains readable. Changing `stream_results` affects subsequent queries and does not bypass this guard. Exhaust or close the stream before reusing the connection; separate connections can run independent streams. Errors discovered during fetching raise during iteration, so always close results, preferably with a block.

On the 30-million-row workload below, streaming reduced peak RSS from 1.15 GB to 45–49 MB on 1.5.6, and from 1.17 GB to 104–110 MB on 2.0.0. Query operators and engine prefetching can still use memory; these are workload measurements.

### Chunk API

`DuckDB::Connection#each_chunk(sql, *args, stream: false)` and `DuckDB::PooledDatabase#each_chunk` yield `DuckDB::DataChunk` values. The explicit stream argument overrides the connection default for that call. A pooled call holds one connection for the entire iteration.

```crystal
require "duckdb"

DB.connect DuckDB::IN_MEMORY do |db|
  cnn = db.as(DuckDB::Connection)
  sql = <<-SQL
    SELECT ?::BIGINT AS id, 12.34::DECIMAL(9,2) AS price,
           'hello'::VARCHAR AS label, [10::BIGINT, NULL, 30::BIGINT] AS items,
           {'name': 'Alice'} AS person
    SQL
  cnn.each_chunk(sql, 7_i64, stream: true) do |chunk|
    puts chunk.column_name(0) # => id
    ids, prices, labels = chunk[0], chunk[1], chunk[2]
    items, people = chunk[3], chunk[4]
    chunk.size.times do |row|
      puts ids.int64(row)       # => 7
      puts prices.decimal(row) # => 12.34
      labels.with_string_bytes(row) { |bytes| puts bytes.size } # => 5
      unless items.null?(row)
        items.each_list_value(row) do |child, index|
          puts child.int64(index) unless child.null?(index) # => 10, then 30
        end
      end
      puts people.struct_child("name").string(row) unless people.null?(row)
    end
  end
end
```

Indices are zero based. Chunks expose `size`, `column_count`, `column_name`, `column_type` (`DuckDB::Type`), and `column`/`[]`. Vector typed accessors match the mapping below: `int8` through `int128`, unsigned equivalents, `float32`, `float64`, `bool`, `string`, `bytes`, `decimal`, `uuid`, `date`, `time_of_day`, `time_tz`, `timestamp`, `interval`, and `big_num`. They require a matching SQL type and a non-NULL row; `null?` checks validity and `value` returns an owned `DuckDB::Value`, including nested containers and NULLs.

`list_size` and `each_list_value` support LIST, MAP, and fixed ARRAY. MAP elements are STRUCTs with `key` and `value` children. `struct_child` accepts a field index or name. `array_child` is flat: element `j` in row `i` is at `i * vector.list_size(i) + j`. Check a STRUCT or ARRAY parent's `null?` before descending; a child's validity does not describe the container. Read UNION through `value`.

**Lifetime rule:** a chunk and every vector derived from it are valid only inside that `each_chunk` block iteration. Later access raises `DuckDB::Exception`. Scalar values and copied `string`, `bytes`, and `value` results may escape. `with_string_bytes` borrows VARCHAR UTF-8 bytes; `with_bytes` borrows BLOB/GEOMETRY bytes. These slices are valid only inside their inner callback: do not retain or mutate them. The callback keeps its buffer alive until it returns, including if the connection closes inside it.

### Appender

Use `connection.appender(table, schema: nil, catalog: nil)` to append rows within that connection's transaction. The block form closes and flushes on exit; a manually created appender must be closed. Connection close also closes its appenders.

Table, schema, and catalog are **literal identifiers**, without SQL quoting. Replace the old `appender("schema.table")` with `appender("table", schema: "schema")`. Dots and quote characters are part of the name; NUL bytes are rejected.

```crystal
require "duckdb"

DB.connect DuckDB::IN_MEMORY do |db|
  cnn = db.as(DuckDB::Connection)
  cnn.exec "CREATE SCHEMA analytics"
  cnn.exec <<-SQL
    CREATE TABLE analytics."event.log"
      (id UHUGEINT, amount DECIMAL(9,2), occurred_at TIMESTAMP_NS)
    SQL
  cnn.appender("event.log", schema: "analytics", catalog: "memory") do |appender|
    appender.row do |row|
      row << 1_u128
      row << DuckDB::Decimal.new(1234_i128, 9, 2)
      row << Time.utc
    end
  end
  puts cnn.scalar("SELECT count(*) FROM analytics.\"event.log\"") # => 1
end
```

The Appender accepts all scalar `DuckDB::Any` values: NULL, booleans, signed/unsigned integers through 128 bits, floats, strings, bytes, UUID, Decimal, BigNum, Date, TimeOfDay, TimeTZ, Timestamp, Interval, and UTC `Time`. BIT uses a string of bits. Nested arrays/hashes are read values and cannot be bound or appended directly.

Rows are buffered in a DuckDB data chunk and handed over 2,048 at a time with `duckdb_append_data_chunk`. A value whose Crystal type matches its column, or widens into it without loss (an `Int32` into BIGINT, say), is written straight into the chunk. Anything else (casts, ENUM columns, narrowing integers, TimeTZ, BigNum) still goes through DuckDB's own conversion. Row order is preserved, and a conversion error is still raised by the `<<` that supplied the value.

For column-oriented data, `append_columns` takes one `Indexable` per destination column, all of the same length, and loads them a chunk at a time. `nil` elements are NULL:

```crystal
require "duckdb"

DB.connect DuckDB::IN_MEMORY do |db|
  cnn = db.as(DuckDB::Connection)
  cnn.exec "CREATE TABLE readings (id BIGINT, label VARCHAR, value DOUBLE)"
  ids = [1, 2, 3]
  labels = ["a", nil, "c"]
  values = [0.5, 1.5, 2.5]
  cnn.appender("readings") { |appender| appender.append_columns(ids, labels, values) }
  puts cnn.scalar("SELECT count(label) FROM readings") # => 2
end
```

`append_columns` accepts only element types that can be written exactly (the same types as above, including lossless integer widening); use `<<` when you need DuckDB to cast. It checks the column count, the lengths and the element types before appending anything. A value that still can't be written (a Decimal with more digits than its column, for example) raises and discards the chunk it was in, up to 2,048 rows; chunks of the same call that came before it stay appended. Call it between rows, not inside `row`.

Exact Decimal and temporal wrappers raise when a destination would discard fractional digits. Decimal-to-float appends also raise; explicitly convert to `Float64` if loss is intended. Stdlib UTC `Time` is represented with its nanoseconds and uses DuckDB's destination cast: a plain TIMESTAMP may truncate on 1.5.6 or round on 2.0.0, while TIMESTAMP_NS retains nanoseconds. DuckDB rejects some TIMESTAMP_NS-to-TIMESTAMP_S/MS casts; those errors propagate. Non-UTC `Time` raises `ArgumentError`.

## Type mapping

These are the results of an untyped `rs.read` or `vector.value`. NULL always returns `nil`, including nested NULLs.

| DuckDB SQL type | Crystal value |
| --- | --- |
| NULL / SQLNULL | `Nil` |
| BOOLEAN | `Bool` |
| TINYINT / SMALLINT / INTEGER / BIGINT / HUGEINT | `Int8` / `Int16` / `Int32` / `Int64` / `Int128` |
| UTINYINT / USMALLINT / UINTEGER / UBIGINT / UHUGEINT | `UInt8` / `UInt16` / `UInt32` / `UInt64` / `UInt128` |
| FLOAT / DOUBLE | `Float32` / `Float64` |
| VARCHAR | `String` |
| BLOB | `Bytes` |
| DECIMAL(w,s) | `DuckDB::Decimal` (unscaled `Int128`, width, scale) |
| UUID | stdlib `UUID` |
| ENUM | `String` |
| LIST / fixed ARRAY | `Array(DuckDB::Value)` |
| STRUCT | `Hash(String, DuckDB::Value)` in declaration order |
| MAP | `Hash(DuckDB::Value, DuckDB::Value)` |
| UNION | Active member's value; an active NULL member is `nil` |
| DATE | `DuckDB::Date` |
| TIME / TIME_NS | `DuckDB::TimeOfDay` |
| TIME_TZ | `DuckDB::TimeTZ` (local time and offset seconds) |
| TIMESTAMP / TIMESTAMP_S / TIMESTAMP_MS / TIMESTAMP_NS | `DuckDB::Timestamp` |
| TIMESTAMP_TZ (SQL TIMESTAMPTZ) | `DuckDB::Timestamp` with TZ provenance |
| TIMESTAMP_TZ_NS (SQL TIMESTAMPTZ_NS, DuckDB 2.0 only) | `DuckDB::Timestamp` with TZ provenance |
| INTERVAL | `DuckDB::Interval` (months, days, microseconds) |
| BIT | `String` of `0` and `1` characters |
| BIGNUM | `DuckDB::BigNum` |
| GEOMETRY | WKB `Bytes` |
| VARIANT | `DuckDB::Exception` for non-NULL values; cast to a concrete SQL type |

`DuckDB::Value` is the recursive result union. `DuckDB::Any` is the scalar parameter union, including UTC `Time`. JSON uses DuckDB's VARCHAR representation; it is not a separate C type enum member.

### Typed reads

`rs.read(T)` supports each scalar above and nilable forms. `read(String)` also formats Decimal, UUID, temporal wrappers, Interval, and BigNum; ENUM and BIT already return strings. It does not stringify arbitrary containers or widen numeric types.

`read(Time)` converts DATE to UTC midnight and all timestamp variants to a UTC instant. For a scalar query, use `.as(DuckDB::Timestamp).to_time` (or the Date equivalent). Typed LIST/ARRAY reads use `read(Array(T))`; STRUCT uses `read(Hash(String, T))`; MAP uses `read(Hash(K, V))`. These conversions recurse, including nullable elements and String/Time conversions; integer widths must match SQL.

```crystal
require "duckdb"

DB.connect DuckDB::IN_MEMORY do |cnn|
  cnn.query <<-SQL do |rs|
    SELECT 12.34::DECIMAL(9,2), TIMESTAMP '2020-01-02 03:04:05',
           [1::BIGINT, NULL, 3::BIGINT], {'name': 'Alice', 'city': 'Denver'}
    SQL
    rs.each do
      puts rs.read(String)                # => 12.34
      puts rs.read(Time).year              # => 2020
      p rs.read(Array(Int64?))             # => [1, nil, 3]
      puts rs.read(Hash(String, String))["name"] # => Alice
    end
  end
end
```

### Temporal semantics

Reads preserve exact engine values. Date stores raw `Int32` days since the Unix epoch, including infinity. Timestamp stores `Int128` nanoseconds with separate infinity and timezone flags, covering every timestamp resolution without a floating-point intermediate. Its `year` is `Int64`; `microseconds` raises if the finite value cannot be expressed exactly as `Int64` microseconds. The legacy Int64 Timestamp constructor still takes microseconds. `to_span` returns the duration since the Unix epoch, raising on infinity or values outside Time::Span's range.

Date and Timestamp text preserves small years, BC dates, and `infinity`/`-infinity`. `to_time` and `read(Time)` raise `DuckDB::Exception` for infinity or years outside 1–9999. Calendar getters raise on infinity; Timestamp's `date` also raises outside the DATE range. No value is clamped. Timestamp equality compares instants; TZ text is UTC with `+00`. TZ provenance does not retain a session display zone or an original offset. TimeTZ retains a local time and numeric UTC offset, rather than a named zone.

TimeOfDay stores nanoseconds since midnight, supports `24:00:00` only with zero smaller fields, and rejects invalid fields or negative durations with `ArgumentError`. Its four-field constructor's last argument and its Int64 constructor remain microseconds; use `from_nanoseconds` for raw nanoseconds. Time and Time::Span constructors preserve nanoseconds; the span constructor requires a nonnegative value strictly shorter than a day. Interval keeps months separate: `to_span` needs an explicit days-per-month approximation when months are nonzero; `to_spans` returns the duration and calendar-month parts separately.

```crystal
require "duckdb"

time = Time.utc(2020, 1, 2, 3, 4, 5, nanosecond: 123_456_789)
timestamp = DuckDB::Timestamp.new(time)
puts timestamp.to_time == time # => true
puts DuckDB::TimeOfDay.new("24:00:00") # => 24:00:00
puts DuckDB::Interval.new(0_i64, 1, 2).to_span(30).days # => 61

DB.connect DuckDB::IN_MEMORY do |cnn|
  exact = cnn.scalar("SELECT ?::TIMESTAMP_NS", timestamp).as(DuckDB::Timestamp)
  puts exact.nanoseconds == timestamp.nanoseconds # => true
  date = cnn.scalar("SELECT DATE 'infinity'").as(DuckDB::Date)
  puts date.infinite? # => true
  begin
    date.to_time
  rescue ex : DuckDB::Exception
    puts "Infinite dates cannot become Crystal Time"
  end
end
```

Binding temporal wrappers and UTC Time first constructs an exact native parameter; subsequent SQL casts follow DuckDB's rules. Values beyond the microsecond range may require an explicit `?::TIMESTAMP_S` or `?::TIMESTAMP_MS` parameter type. Unsupported native representations raise instead of truncating. Non-microsecond TZ Timestamp binding raises on both supported engines because the required constructor is absent from the common 1.5.x C API. On DuckDB 2.0 the Appender writes such values exactly into TIMESTAMP_TZ_NS columns. Microsecond-aligned TZ instants bind exactly. Appender destination precision checks are described above.

### DECIMAL and optional big-number conversions

`DuckDB::Decimal` supports widths 1–38. Its `value` is the unscaled integer: `1234` with scale 2 means `12.34`. Formatting, comparison, hashing, reads, and bindings are exact; `to_f64` is explicitly lossy. BigNum owns arbitrary-precision integer bytes and formats them without GMP. Loading `duckdb` alone does not require GMP. Add `require "duckdb/big"` for Decimal's `to_big_d` and BigNum's `to_big_i`:

```crystal
require "duckdb/big"

DB.connect DuckDB::IN_MEMORY do |cnn|
  amount = DuckDB::Decimal.new(1234_i128, 9, 2)
  result = cnn.scalar("SELECT ?::DECIMAL(9,2)", amount).as(DuckDB::Decimal)
  puts result.to_big_d == BigDecimal.new("12.34") # => true
  integer = cnn.scalar("SELECT '1234567890123456789012345678901234567890'::BIGNUM")
  puts integer.as(DuckDB::BigNum).to_big_i
end
```

## Performance

Snapshot measured on 2026-11-02 at implementation commit `c8de4dd` on a Linux x86-64 laptop: release builds pinned to four cores, DuckDB `threads=4`, medians of five interleaved runs. The machine was not idle, so treat these numbers as approximately ±10%; they describe these queries and consumption patterns.

The end-to-end query generates five columns (BIGINT, DOUBLE, VARCHAR, BOOLEAN, DATE) over five million rows. Timing includes DuckDB execution, typed reads, and checksum accumulation:

| DuckDB | Old reader (`1adee51`), M rows/s | 0.3.0 ResultSet `read(T)`, M rows/s |
| --- | ---: | ---: |
| 1.5.6 | 2.07 | 7.36 |
| 2.0.0 | 1.72 | 7.52 |

For a pre-built five-million-row table, query generation is outside the timer. Rates below are millions of rows per second:

| Read mode | 1.5.6 | 2.0.0 |
| --- | ---: | ---: |
| Fetch chunks, no value reads | 56.5 | 33.8 |
| ResultSet iteration, no value reads | 59.5 | 35.1 |
| ResultSet typed reads, all five columns | 11.6 | 11.0 |
| ResultSet untyped reads, all five columns | 9.4 | 8.8 |
| each_chunk, all five columns, copied strings | 16.3 | 13.9 |
| each_chunk, all five columns, `with_string_bytes` | 43.7 | 31.2 |
| ResultSet BIGINT only | 114.2 | 114.9 |
| ResultSet DOUBLE only | 97.0 | 114.0 |
| ResultSet VARCHAR only | 18.4 | 15.7 |
| ResultSet BOOLEAN only | 156.3 | 149.1 |
| ResultSet DATE only | 141.0 | 115.2 |
| each_chunk BIGINT only | 340.6 | 256.5 |

Copying VARCHAR values accounts for much of the read cost in this workload. Borrowed bytes avoid creating a String for each value when a consumer only needs bytes.

The memory comparison generates 30 million rows with the same five types, consuming them through `each_chunk` and `with_string_bytes`. Peak RSS is measured by `/usr/bin/time -f %M`:

| DuckDB | Materialized: elapsed, peak RSS | Streaming: elapsed, peak RSS |
| --- | --- | --- |
| 1.5.6 | 2.42 s, 1.15 GB | 1.87–1.95 s, 45–49 MB |
| 2.0.0 | 2.13 s, 1.17 GB | 1.80–1.86 s, 104–110 MB |

See [bench/README.md](bench/README.md) for release-build commands, library paths, and reproduction using `read_bench.cr`, `read_breakdown.cr`, and `stream_memory.cr`. The old-reader comparison requires a separate baseline build from `1adee51`; current benchmarks measure the current driver.

## Known issues

- Non-NULL VARIANT values raise, including inside nested values. NULL VARIANT reads return nil. Cast to a supported concrete SQL type.
- Non-microsecond TZ Timestamp values cannot be bound through the common C API. The Appender writes them into TIMESTAMP_TZ_NS columns on DuckDB 2.0.
- Nested parameter/Appender construction is not implemented; use SQL constructors or casts with scalar parameters.
- crystal-db 0.13.1–0.15.0 pools can give one newly built connection to two fibers when the pool grows under parallel execution contexts. Pools created with `DB.open` on a DuckDB URI use a driver pool that avoids this; a manually constructed `DB::Database` or `DB::Pool` does not.
- Windows is untested; upstream [issue #2](https://github.com/amauryt/crystal-duckdb/issues/2) reports abnormal termination.
- macOS is not in CI. The spec suite's native-handle counters use GNU ld `--wrap`, so specs run on Linux.
- DuckDB 1.4.x is not officially supported.
- Streaming currently uses DuckDB's deprecated but exported v1 streaming entry point; the newer v2 C API is unstable.

## Contributing

On Linux amd64, run a CI cell locally; the script downloads and verifies the pinned official library, installs shards, and runs the specs:

```sh
scripts/ci-local.sh 1.5.6 "$PWD/.tmp/duckdb"
scripts/ci-local.sh 2.0.0 "$PWD/.tmp/duckdb"
```

Or use an installed library:

```sh
shards install
export LIBRARY_PATH="/absolute/path/to/duckdb"
export LD_LIBRARY_PATH="$LIBRARY_PATH"
crystal spec
```

Every Crystal block in this README is a standalone program. `scripts/check-readme.sh` extracts, compiles, and runs each one in a temporary directory, then removes it. CI runs this after the specs in every DuckDB/Crystal matrix cell, including the minimum Crystal version. Run it locally with the same library paths:

```sh
LIBRARY_PATH="$PWD/.tmp/duckdb/duckdb-2.0.0" \
LD_LIBRARY_PATH="$PWD/.tmp/duckdb/duckdb-2.0.0" scripts/check-readme.sh
```

Use the corresponding version directory for the other matrix cell. The example check is separate from `crystal spec` because it compiles every program independently. Include specs for behavior changes and keep both engine versions passing. Contributions go to [this fork](https://github.com/wyhaines/crystal-duckdb).

## Contributors

- [Amaury Trujillo](https://github.com/amauryt) — creator of the shard.
- [Kirk Haines](https://github.com/wyhaines) — maintainer of this fork.
