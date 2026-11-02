require "../src/duckdb"

# Breakdown of read cost on a pre-built table, so DuckDB's query work is small
# and constant. Prints median rows/s per mode over interleaved repeats.
# Usage: read_breakdown [positive row count = 5000000] [positive repeats = 5]
N       = (ARGV[0]? || "5000000").to_i64
REPEATS = (ARGV[1]? || "5").to_i
raise "row count and repeats must be positive" unless N > 0 && REPEATS > 0

DB.connect "duckdb::memory:?threads=4" do |db|
  cnn = db.as(DuckDB::Connection)
  cnn.exec "CREATE TABLE t AS SELECT i::BIGINT AS b, i::DOUBLE AS d, 'str' || i::VARCHAR AS s, i % 2 = 0 AS f, DATE '2020-01-01' + (i % 1000)::INTEGER AS dt FROM range(#{N}) t(i)"

  sink = 0_i64
  modes = {
    "fetch only (each_chunk, no reads)" => ->{
      cnn.each_chunk("SELECT * FROM t") { |chunk| sink &+= chunk.size }
    },
    "each_chunk, all 5 columns" => ->{
      cnn.each_chunk("SELECT * FROM t") do |chunk|
        b, d, s, f, dt = chunk[0], chunk[1], chunk[2], chunk[3], chunk[4]
        chunk.size.times do |r|
          sink &+= b.int64(r) &+ d.float64(r).to_i64 &+ s.string(r).bytesize &+ (f.bool(r) ? 1 : 0) &+ dt.date(r).days
        end
      end
    },
    "each_chunk, all 5, string via with_string_bytes" => ->{
      cnn.each_chunk("SELECT * FROM t") do |chunk|
        b, d, s, f, dt = chunk[0], chunk[1], chunk[2], chunk[3], chunk[4]
        chunk.size.times do |r|
          s.with_string_bytes(r) { |bytes| sink &+= bytes.size }
          sink &+= b.int64(r) &+ d.float64(r).to_i64 &+ (f.bool(r) ? 1 : 0) &+ dt.date(r).days
        end
      end
    },
    "ResultSet iterate only (no reads)" => ->{
      cnn.query("SELECT * FROM t") { |rs| rs.each { sink &+= 1 } }
    },
    "ResultSet read(T), all 5 columns" => ->{
      cnn.query("SELECT * FROM t") do |rs|
        rs.each do
          sink &+= rs.read(Int64) &+ rs.read(Float64).to_i64 &+ rs.read(String).bytesize &+ (rs.read(Bool) ? 1 : 0) &+ rs.read(DuckDB::Date).days
        end
      end
    },
    "ResultSet read (untyped), all 5" => ->{
      cnn.query("SELECT * FROM t") do |rs|
        rs.each { 5.times { sink &+= rs.read.hash.to_i64! } }
      end
    },
    "ResultSet read(Int64), BIGINT only" => ->{
      cnn.query("SELECT b FROM t") { |rs| rs.each { sink &+= rs.read(Int64) } }
    },
    "ResultSet read(Float64), DOUBLE only" => ->{
      cnn.query("SELECT d FROM t") { |rs| rs.each { sink &+= rs.read(Float64).to_i64 } }
    },
    "ResultSet read(String), VARCHAR only" => ->{
      cnn.query("SELECT s FROM t") { |rs| rs.each { sink &+= rs.read(String).bytesize } }
    },
    "ResultSet read(Bool), BOOLEAN only" => ->{
      cnn.query("SELECT f FROM t") { |rs| rs.each { sink &+= rs.read(Bool) ? 1 : 0 } }
    },
    "ResultSet read(Date), DATE only" => ->{
      cnn.query("SELECT dt FROM t") { |rs| rs.each { sink &+= rs.read(DuckDB::Date).days } }
    },
    "each_chunk int64, BIGINT only" => ->{
      cnn.each_chunk("SELECT b FROM t") { |chunk| v = chunk[0]; chunk.size.times { |r| sink &+= v.int64(r) } }
    },
  }

  times = Hash(String, Array(Float64)).new { |h, k| h[k] = [] of Float64 }
  REPEATS.times do |rep|
    order = modes.keys
    order.reverse! if rep.odd?
    order.each { |name| times[name] << Time.measure { modes[name].call }.total_seconds }
  end
  modes.keys.each do |name|
    t = times[name].sort[times[name].size // 2]
    printf "%-48s %8.3f s  %8.2f M rows/s\n", name, t, N / t / 1e6
  end
  puts "sink=#{sink}"
end
