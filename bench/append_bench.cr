require "../src/duckdb"

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
measure_append "DECIMAL(18,3)", DuckDB::Decimal.new(1234567891234_i128, 18, 3)
measure_append "DECIMAL(38,10)", DuckDB::Decimal.new(12345678912345678901234567890_i128, 38, 10)
measure_append "TIMESTAMP", DuckDB::Timestamp.new(Time.utc(2026, 1, 2, 3, 4, 5, nanosecond: 123456000))

rates = [] of Float64
repeats.times do
  DB.connect "duckdb::memory:?threads=4" do |db|
    cnn = db.as(DuckDB::Connection)
    cnn.exec("CREATE TABLE data (n BIGINT, label VARCHAR, d DECIMAL(18,3), t TIMESTAMP, b BOOLEAN)")
    decimal = DuckDB::Decimal.new(1234567891234_i128, 18, 3)
    timestamp = DuckDB::Timestamp.new(Time.utc(2026, 1, 2, 3, 4, 5, nanosecond: 123456000))
    elapsed = Time.measure do
      cnn.appender("data") do |appender|
        count.times { |i| appender.row { |row| row << i << "DuckDB appender benchmark string" << decimal << timestamp << true } }
      end
    end
    raise "wrong mixed count" unless cnn.scalar("SELECT count(*) FROM data") == count
    raise "wrong mixed sum" unless cnn.scalar("SELECT sum(n)::BIGINT FROM data") == count.to_i64 * (count - 1) // 2
    rates << count / elapsed.total_seconds
  end
end
puts "mixed N=#{count} median_rows/s=#{rates.sort[rates.size // 2].round.to_i64}"

# Input construction is outside the timed load for both implementations.
numbers = Array(Int64).new(count) { |i| i.to_i64 }
labels = Array(String).new(count, "DuckDB appender benchmark string")
decimals = Array(DuckDB::Decimal).new(count, DuckDB::Decimal.new(1234567891234_i128, 18, 3))
timestamps = Array(DuckDB::Timestamp).new(count, DuckDB::Timestamp.new(Time.utc(2026, 1, 2, 3, 4, 5, nanosecond: 123456000)))
bools = Array(Bool).new(count, true)
rates.clear
repeats.times do
  DB.connect "duckdb::memory:?threads=4" do |db|
    cnn = db.as(DuckDB::Connection)
    cnn.exec("CREATE TABLE data (n BIGINT, label VARCHAR, d DECIMAL(18,3), t TIMESTAMP, b BOOLEAN)")
    elapsed = Time.measure do
      cnn.appender("data") do |appender|
        {% if flag?(:native_append_baseline) %}
          count.times { |i| appender.row { |row| row << numbers[i] << labels[i] << decimals[i] << timestamps[i] << bools[i] } }
        {% else %}
          appender.append_columns(numbers, labels, decimals, timestamps, bools)
        {% end %}
      end
    end
    raise "wrong columnar count" unless cnn.scalar("SELECT count(*) FROM data") == count
    raise "wrong columnar sum" unless cnn.scalar("SELECT sum(n)::BIGINT FROM data") == count.to_i64 * (count - 1) // 2
    rates << count / elapsed.total_seconds
  end
end
puts "columnar(mixed) N=#{count} median_rows/s=#{rates.sort[rates.size // 2].round.to_i64}"
