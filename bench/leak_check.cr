require "../src/duckdb"

lib LeakCheckLibC
  fun getpagesize : Int32
end

def rss_kib
  File.read("/proc/self/statm").split[1].to_i64 * LeakCheckLibC.getpagesize // 1024
end

iterations = (ARGV[0]? || "20000").to_i
raise "iterations must be at least 10" if iterations < 10
interval = Math.max(iterations // 10, 1)

# Use a fresh database for each case, with no table growth or statement-cache growth.
cases = {
  "prepared query"            => ->(cnn : DB::Connection) {
    cnn.query("SELECT ?::BIGINT", 42) { |rs| rs.each { rs.read(Int64) } }
  },
  "prepared exec"             => ->(cnn : DB::Connection) {
    cnn.exec("SELECT repeat('x', 4096)")
  },
  "unprepared exec"           => ->(cnn : DB::Connection) {
    cnn.unprepared.exec("SELECT repeat('x', 4096)")
  },
  "failing prepared exec"     => ->(cnn : DB::Connection) {
    begin
      cnn.exec("SELECT CAST(? AS INTEGER)", "bad")
    rescue DuckDB::Exception
    end
  },
  "failing unprepared exec"   => ->(cnn : DB::Connection) {
    begin
      cnn.unprepared.exec("SELECT CAST('bad' AS INTEGER)")
    rescue DuckDB::Exception
    end
  },
}

cases.each do |name, operation|
  # duckdb::memory: bypasses the original bracketed-host URI bug for the baseline.
  DB.connect "duckdb::memory:" do |cnn|
    100.times { operation.call(cnn) }
    GC.collect
    puts "#{name} (KiB), 0:#{rss_kib}"
    iterations.times do |i|
      operation.call(cnn)
      if (i + 1) % interval == 0 || i + 1 == iterations
        GC.collect
        puts "#{name} (KiB), #{i + 1}:#{rss_kib}"
      end
    end
  end
end
