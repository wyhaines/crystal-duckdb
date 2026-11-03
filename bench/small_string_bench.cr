require "../src/duckdb"

# Usage: small_string_bench [executions=20000] [deduplicate_strings=false]
# A cached prepared SELECT returns one row of twenty VARCHAR columns. Includes
# execution, reading and close; excludes connection, preparation and explicit GC.
count = (ARGV[0]? || "20000").to_i
option = ARGV[1]? || "false"
raise "executions must be positive" unless count > 0
sql = "SELECT " + (0...20).map { |i| "'small'::VARCHAR AS s#{i}" }.join(", ")
DB.connect "duckdb::memory:?threads=4&deduplicate_strings=#{option}" do |db|
  statement = db.prepared(sql)
  checksum = 0_i64
  GC.collect
  before = GC.stats
  elapsed = Time.measure do
    count.times do
      statement.query do |rs|
        raise "missing row" unless rs.move_next
        20.times { checksum &+= rs.read(String).bytesize }
        raise "extra row" if rs.move_next
      end
    end
  end
  after = GC.stats
  raise "wrong checksum" unless checksum == count.to_i64 * 20 * 5
  puts "executions,deduplicate_strings,seconds,allocated_bytes,heap_before,heap_after,checksum"
  puts "#{count},#{option},#{elapsed.total_seconds},#{after.total_bytes - before.total_bytes},#{before.heap_size},#{after.heap_size},#{checksum}"
end
