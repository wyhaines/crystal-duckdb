# Benchmarks

Run from the repository root with Crystal, shards, and a supported official DuckDB C shared library installed. These programs use generated data and anonymous memory databases. They require no fixtures and create no database files.

## Build

Install dependencies with `shards install`. Set both library paths to the same engine directory. On Linux, use release builds and serialize compilation against the checkout's cache:

```sh
export LIBRARY_PATH=/absolute/path/to/duckdb
export LD_LIBRARY_PATH="$LIBRARY_PATH"
export CRYSTAL_CACHE_DIR="$PWD/.cache/crystal"
export SHARDS_CACHE_PATH="$PWD/.cache/shards"
export TMPDIR="$PWD/.tmp"
mkdir -p "$CRYSTAL_CACHE_DIR" "$SHARDS_CACHE_PATH" "$TMPDIR"
(
  flock 9
  for name in read_bench read_breakdown stream_memory; do
    # Cache guard: keep immediately before every compile.
    test -n "$CRYSTAL_CACHE_DIR"
    test -d "$CRYSTAL_CACHE_DIR"
    taskset -c 12-15 crystal build --release "bench/$name.cr" -o ".tmp/$name"
  done
) 9>"$TMPDIR/compile.lock"
```

The README measurements pinned four cores with `taskset`; choose available CPUs on your machine, keeping the same affinity for builds and runs. Each program requests DuckDB `threads=4`. On macOS, omit `taskset`, use `DYLD_LIBRARY_PATH` if needed, and use a local lock tool instead of GNU `flock`.

## End-to-end reads: read_bench.cr

```sh
taskset -c 12-15 .tmp/read_bench 5000000 5
```

Arguments are row count and repeat count (defaults: one million and five million rows, three repeats per size). The query generates BIGINT, DOUBLE, VARCHAR, BOOLEAN, and DATE columns. Timing includes materialized execution, typed ResultSet reads, and checksums. Each run prints rows/s and checksum values; the final line reports median rows/s.

The README's old-reader comparison used the same benchmark and crystal-db dependency against upstream commit `1adee51`, with only the required `Connection#driver_name` compatibility method added to that baseline build. Reproducing the old column requires a separate copy of that source and benchmark; these commands build the current driver. Keep old and current source/dependency/compiler settings identical apart from that compatibility method, verify matching checksums, and alternate executable order across runs against each selected engine.

## Read breakdown: read_breakdown.cr

```sh
taskset -c 12-15 .tmp/read_breakdown 5000000 5
```

Arguments are row count and repeats (defaults: 5,000,000 and 5). It builds a five-column table before timing. It measures chunk fetching without reads, ResultSet iteration, typed and untyped reads, individual SQL types, public typed chunks with copied strings, and chunks borrowing strings through `with_string_bytes`. Modes run in alternating order between repetitions; output reports median elapsed time and M rows/s for each mode. The sink keeps consumption observable; untyped reads hash values, so that mode includes hashing cost. Setup and table creation are excluded; query execution and consumption are included.

## Streaming memory: stream_memory.cr

```sh
/usr/bin/time -f 'peak RSS: %M KiB' taskset -c 12-15 .tmp/stream_memory 30000000 materialized
/usr/bin/time -f 'peak RSS: %M KiB' taskset -c 12-15 .tmp/stream_memory 30000000 stream
```

Arguments are row count and `materialized` or `stream`. Each process generates the five-column result and consumes it through `each_chunk`, borrowing strings. The program reports execution-plus-consumption time, throughput, and a checksum; GNU time reports whole-process peak RSS in KiB. Run each mode in a fresh process and repeat in alternating order to compare memory and timing. Checksums should agree. Streaming memory includes DuckDB's operators and prefetch buffers, and depends on the query and engine.

Repeat against each library by changing `LIBRARY_PATH` and `LD_LIBRARY_PATH` and rebuilding. The README snapshot used release builds, the settings above, and five interleaved breakdown/end-to-end runs. Host load was about 8.6 with another process using about 43% of one selected CPU; treat those reported rates as approximately ±10%.

## Other programs

`chunk_bench.cr` compares copied-string chunks with typed ResultSet reads on the generated five-column query. `append_bench.cr` measures scalar Appender rows for BIGINT, VARCHAR, DECIMAL, and TIMESTAMP. `leak_check.cr` samples Linux process RSS over repeated successful and failing query/exec operations. Build each with the same release command and cache guard, substituting its filename. Their arguments and defaults are documented in the source. RSS plateaus over these bounded workloads complement the spec suite's native-handle counters; they do not establish behavior for every workload.

## VARCHAR allocation and GC: string_bench.cr

Build `bench/string_bench.cr` with the release environment and compile lock above.
It defaults to five million rows, three interleaved repeats per mode, lengths 12
(DuckDB inline), 32 and 200 bytes, and cardinalities 16, 10,000 and all-distinct.
Each table is generated before timing. Every sample reports materialized SELECT
execution separately from consumption, plus their total, a checked byte count,
GC allocation/heap statistics before and after, collection count and collection
time. Boehm collection events and gcry's pause counters provide collection time;
allocator work outside collection remains in consumption time.

```sh
taskset -c 12-15 .tmp/string_bench 5000000 3 all on all
taskset -c 12-15 .tmp/string_bench 5000000 3 all off typed
taskset -c 12-15 .tmp/string_bench 5000000 3 all on typed all deduplicate_strings=true
```

`deduplicate_strings` is a core driver option, off by default. The same binary
runs both policies; no extension require or separate cache wrapper is needed.
Its per-column table is allocated at the first non-NULL read, starts at 64 slots,
and doubles at half full up to 32,768 slots. Entries retain their hash for growth;
no borrowed DuckDB pointer is retained.

Arguments are rows, repeats, length (`all`, `12`, `32`, `200`), GC (`on`, `off`),
comma-separated modes (or `all`), cardinality (`all`, `16`, `10000`, `distinct`),
and optional connection URI parameters. Modes are `fetch`, `iterate`, `typed`
(`read(String)`), `nullable` (`read(String?)`), `untyped` (`read`), `vector`
(`Vector#string`), `bytes` (`with_string_bytes`), `raw` (internal `VectorView#string`,
without public guards), and `allocate` (copies one Crystal source String, without
querying DuckDB). Except for fetch/iteration, checksums sum bytesizes, so untyped
reads add no hashing or formatting. GC is explicitly collected before each
sample, outside timing; disabled runs re-enable it after each sample. A disabled
sample can retain over 1 GB of garbage at length 200. This is an allocation
microbenchmark: real applications with larger live heaps can collect differently.

Run one benchmark or compile at a time, alternating baseline/current and
collector order across fresh processes. Report medians and min/max spreads,
including consumption separately when execution noise masks a small difference.
For gcry, use a temporary wrapper that requires the pinned `gcry/src/gcry` before
requiring the benchmark, build with `-Dgc_none`, and run with
`GCRY_NURSERY=0`.
No collector dependency is needed in this driver's shard.yml. gcry requires
Crystal >= 1.21; record its exact commit and configuration with the results.

## Many small string results: small_string_bench.cr

Build with the same guarded release environment. Run off and on in alternating
order, for example `.tmp/small_string_bench 20000 false` and
`.tmp/small_string_bench 20000 true`. Each execution of a cached prepared SELECT
returns one row of twenty VARCHAR columns. Output includes elapsed time,
GC.stats total allocation and a checked byte count; connection setup,
preparation and explicit pre-run collection are excluded. This exposes table
setup costs that a five-million-row scan amortizes away.
