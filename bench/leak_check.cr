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
  "chunk appender"            => ->(db : DB::Connection) {
    cnn = db.as(DuckDB::Connection)
    cnn.exec("BEGIN TRANSACTION")
    begin
      cnn.appender("append_values") do |a|
        4097.times { |i| a.row { |r| r << i << DuckDB::Decimal.new(123_i128, 18, 3) << "label" } }
        a.row { |r| r << "4097" << DuckDB::Decimal.new(123_i128, 18, 3) << "cast" }
        a.append_columns([4098, 4099], [DuckDB::Decimal.new(123_i128, 18, 3)] * 2, ["column", "column"])
      end
    ensure
      # Rollback avoids table/row-group growth being mistaken for a handle leak.
      cnn.exec("ROLLBACK")
    end
  },
  "failing chunk appender"    => ->(db : DB::Connection) {
    cnn = db.as(DuckDB::Connection)
    begin
      cnn.appender("append_values") do |a|
        a.row { |r| r << 1 << DuckDB::Decimal.new(123_i128, 18, 3) << "label" }
        a << 2 << "bad"
      end
    rescue DuckDB::Exception
    end
  },
  "failing appender close"    => ->(db : DB::Connection) {
    cnn = db.as(DuckDB::Connection)
    begin
      cnn.appender("append_values") { |a| a.row { |r| r << 1 << DuckDB::Decimal.new(123_i128, 18, 3) << nil } }
    rescue DuckDB::Exception
    end
  },
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
    cnn.exec("CREATE TABLE append_values (n BIGINT, d DECIMAL(18,3), label VARCHAR NOT NULL)")
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
