require "../src/duckdb"

# Before exact Decimal appending existed, use its exact text cast as the baseline.
# Run with --release; includes appender creation, row calls, flushing and close.
count = (ARGV[0]? || "500000").to_i
repeats = (ARGV[1]? || "3").to_i
macro measure_append(sql_type, value)
  rates = [] of Float64
  repeats.times do
    DB.connect "duckdb::memory:?threads=4" do |db|
      cnn = db.as(DuckDB::Connection)
      cnn.exec("CREATE TABLE data (v {{sql_type.id}})")
      value = {{value}}
      elapsed = Time.measure do
        cnn.appender("data") do |appender|
          count.times { appender.row { |row| row << value } }
        end
      end
      raise "wrong count" unless cnn.scalar("SELECT count(*) FROM data") == count
      rates << count / elapsed.total_seconds
    end
  end
  puts "{{sql_type.id}} N=#{count} median_rows/s=#{rates.sort[rates.size // 2].round.to_i64}"
end

measure_append "BIGINT", 123456789_i64
measure_append "VARCHAR", "DuckDB appender benchmark string"
measure_append "DECIMAL(18,4)", DuckDB::Decimal.new(1234567891234_i128, 18, 4)
measure_append "TIMESTAMP", DuckDB::Timestamp.new(Time.utc(2026, 1, 2, 3, 4, 5, nanosecond: 123456000))
