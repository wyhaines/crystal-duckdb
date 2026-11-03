require "../src/duckdb"

# Usage: string_bench [rows=5000000] [repeats=3] [shape=all|12|32|200]
#   [gc=on|off] [modes=all|comma,separated] [cardinality=all|16|10000|distinct]
#   [URI options, e.g. deduplicate_strings=true; core option, no extra require]
# Table generation and explicit GC.collect are outside all timings. Every mode
# executes a materialized SELECT; execution and subsequent consumption are split.
# The raw mode deliberately bypasses public guards to isolate String allocation.
struct DuckDB::Vector
  def benchmark_view : DuckDB::VectorView
    @view
  end
end

# Collection callbacks are outside the value loop; no tracing build is needed.
module StringBenchGC
  @@start = 0_i64
  @@nanoseconds = 0_i64

  def self.install
    {% unless flag?(:gc_none) %}
      LibGC.set_on_collection_event(->(event : LibGC::EventType) {
        if event.start?
          @@start = Time.monotonic.total_nanoseconds.to_i64
        elsif event.end?
          @@nanoseconds += Time.monotonic.total_nanoseconds.to_i64 - @@start
        end
        nil
      })
    {% end %}
  end

  def self.nanoseconds
    {% if flag?(:gc_none) %}
      Gcry.pause_stats.total_ns.to_i64
    {% else %}
      @@nanoseconds
    {% end %}
  end
end

StringBenchGC.install
rows = (ARGV[0]? || "5000000").to_i64
repeats = (ARGV[1]? || "3").to_i
shapes = (ARGV[2]? || "all") == "all" ? [12, 32, 200] : [ARGV[2].to_i]
disabled = (ARGV[3]? || "on") == "off"
all_modes = %w[fetch iterate typed nullable untyped vector bytes raw allocate]
modes = (ARGV[4]? || "all") == "all" ? all_modes : ARGV[4].split(',')
cards = (ARGV[5]? || "all") == "all" ? ["16", "10000", "distinct"] : [ARGV[5]]
options = ARGV[6]? || ""
raise "positive rows/repeats, shapes >= 7, known modes required" unless rows > 0 && repeats > 0 && shapes.all? { |n| n >= rows.to_s.size } && modes.all? { |m| all_modes.includes?(m) }
puts "shape,cardinality,gc,mode,repeat,execute_s,consume_s,total_s,mvalues_s,allocated_bytes,heap_before,heap_after,free_before,free_after,since_gc_before,since_gc_after,collections,gc_s,checksum"
STDOUT.flush
shapes.each do |length|
  cards.each do |card|
    cardinality = card == "distinct" ? rows : card.to_i64
    raise "cardinality must be positive" unless cardinality > 0
    DB.connect "duckdb::memory:?threads=4&#{options}" do |db|
      cnn = db.as(DuckDB::Connection)
      cnn.exec "CREATE TABLE strings AS SELECT lpad((i % #{cardinality})::VARCHAR, #{length}, 'x') AS s FROM range(#{rows}) t(i)"
      source = "x" * length
      repeats.times do |rep|
        order = rep.odd? ? modes.reverse : modes
        order.each do |mode|
          GC.collect
          before = GC.stats
          collections = GC.prof_stats.gc_no
          gc_ns = StringBenchGC.nanoseconds
          GC.disable if disabled
          checksum = 0_i64
          execute = 0.0
          begin
            start = Time.monotonic
            if mode == "allocate"
              rows.times { checksum &+= String.new(source.to_unsafe, source.bytesize).bytesize }
            else
              cnn.query("SELECT s FROM strings") do |rs|
                execute = (Time.monotonic - start).total_seconds
                if mode == "fetch" || mode == "vector" || mode == "bytes" || mode == "raw"
                  rs.as(DuckDB::ResultSet).each_chunk do |chunk|
                    if mode == "fetch"
                      checksum &+= chunk.size
                    else
                      vector = chunk[0]
                      view = vector.benchmark_view
                      case mode
                      when "vector"
                        chunk.size.times { |row| checksum &+= vector.string(row).bytesize }
                      when "bytes"
                        chunk.size.times { |row| vector.with_string_bytes(row) { |bytes| checksum &+= bytes.size } }
                      when "raw"
                        chunk.size.times { |row| checksum &+= view.string(row).bytesize }
                      end
                    end
                  end
                else
                  case mode
                  when "iterate"  then rs.each { checksum &+= 1 }
                  when "typed"    then rs.each { checksum &+= rs.read(String).bytesize }
                  when "nullable" then rs.each { checksum &+= rs.read(String?).not_nil!.bytesize }
                  when "untyped"  then rs.each { checksum &+= rs.read.as(String).bytesize }
                  end
                end
              end
            end
            total = (Time.monotonic - start).total_seconds
            after = GC.stats
            collections_delta = GC.prof_stats.gc_no - collections
            gc_seconds = (StringBenchGC.nanoseconds - gc_ns) / 1e9
            expected = (mode == "fetch" || mode == "iterate") ? rows : rows * length
            raise "wrong checksum #{checksum}, expected #{expected}" unless checksum == expected
            puts "#{length},#{card},#{disabled ? "off" : "on"},#{mode},#{rep},#{execute},#{total - execute},#{total},#{rows / total / 1e6},#{after.total_bytes - before.total_bytes},#{before.heap_size},#{after.heap_size},#{before.free_bytes},#{after.free_bytes},#{before.bytes_since_gc},#{after.bytes_since_gc},#{collections_delta},#{gc_seconds},#{checksum}"
            STDOUT.flush
          ensure
            GC.enable if disabled
          end
        end
      end
    end
  end
end
