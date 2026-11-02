require "../src/duckdb"

# Peak-memory comparison: read a large generated result once, either
# materialized or streamed, through each_chunk with zero-copy strings.
# Usage: stream_memory <positive row count> <materialized|stream>
unless ARGV.size == 2 && {"materialized", "stream"}.includes?(ARGV[1])
  STDERR.puts "Usage: stream_memory <positive row count> <materialized|stream>"
  exit 2
end
n = ARGV[0].to_i64
raise "row count must be positive" unless n > 0
stream = ARGV[1] == "stream"
sink = 0_i64
DB.connect "duckdb::memory:?threads=4" do |db|
  cnn = db.as(DuckDB::Connection)
  sql = "SELECT i::BIGINT, i::DOUBLE, 'str' || i::VARCHAR, i % 2 = 0, DATE '2020-01-01' + (i % 1000)::INTEGER FROM range(#{n}) t(i)"
  elapsed = Time.measure do
    cnn.each_chunk(sql, stream: stream) do |chunk|
      b, d, s, f, dt = chunk[0], chunk[1], chunk[2], chunk[3], chunk[4]
      chunk.size.times do |r|
        s.with_string_bytes(r) { |bytes| sink &+= bytes.size }
        sink &+= b.int64(r) &+ d.float64(r).to_i64 &+ (f.bool(r) ? 1 : 0) &+ dt.date(r).days
      end
    end
  end
  printf "%s n=%d %.3f s %.2f M rows/s sink=%d\n", (stream ? "stream" : "materialized"), n, elapsed.total_seconds, n / elapsed.total_seconds / 1e6, sink
end
