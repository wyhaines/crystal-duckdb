require "../src/duckdb"

# Includes materialized execution and typed consumption. Run both sizes by
# default; the optional second argument repeats each size for median timings.
sizes = ARGV[0]? ? [ARGV[0].to_i64] : [1_000_000_i64, 5_000_000_i64]
repeats = (ARGV[1]? || "3").to_i
sizes.each do |count|
  rates = [] of Float64
  repeats.times do
    DB.connect "duckdb::memory:?threads=4" do |cnn|
      sql = "SELECT i::BIGINT, i::DOUBLE, 'str' || i::VARCHAR, i % 2 = 0, DATE '2020-01-01' + (i % 1000)::INTEGER FROM range(#{count}) t(i)"
      rows = 0_i64
      checksum = 0_i64
      floats = 0.0
      last_date = DuckDB::Date.new(2020, 1, 1)
      elapsed = Time.measure do
        cnn.query(sql) do |rs|
          rs.each do
            checksum &+= rs.read(Int64)
            floats += rs.read(Float64)
            checksum &+= rs.read(String).bytesize
            checksum &+= rs.read(Bool) ? 1 : 0
            last_date = rs.read(DuckDB::Date)
            rows += 1
          end
        end
      end
      raise "wrong row count" unless rows == count
      rate = rows / elapsed.total_seconds
      rates << rate
      puts "N=#{count} seconds=#{elapsed.total_seconds.round(6)} rows/s=#{rate.round.to_i64} checksum=#{checksum} double=#{floats.to_i64} date=#{last_date}"
    end
  end
  puts "N=#{count} median_rows/s=#{rates.sort[rates.size // 2].round.to_i64}"
end
