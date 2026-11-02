require "../src/duckdb"

# Identical query, consumption and checksum to read_bench.cr. Includes execution.
count = (ARGV[0]? || "5000000").to_i64
repeats = (ARGV[1]? || "3").to_i
mode = ARGV[2]? || "both"
rates = Hash(String, Array(Float64)).new { |hash, key| hash[key] = [] of Float64 }
repeats.times do |repeat|
  modes = mode == "both" ? ["chunk", "result"] : [mode]
  modes.reverse! if repeat.odd?
  modes.each do |reader|
    DB.connect "duckdb::memory:?threads=4" do |db|
      cnn = db.as(DuckDB::Connection)
      sql = "SELECT i::BIGINT, i::DOUBLE, 'str' || i::VARCHAR, i % 2 = 0, DATE '2020-01-01' + (i % 1000)::INTEGER FROM range(#{count}) t(i)"
      rows = 0_i64
      checksum = 0_i64
      floats = 0.0
      last_date = DuckDB::Date.new(2020, 1, 1)
      elapsed = Time.measure do
        if reader == "chunk"
          cnn.each_chunk(sql) do |chunk|
            integers, doubles, strings, bools, dates = chunk[0], chunk[1], chunk[2], chunk[3], chunk[4]
            chunk.size.times do |row|
              checksum &+= integers.int64(row)
              floats += doubles.float64(row)
              checksum &+= strings.string(row).bytesize
              checksum &+= bools.bool(row) ? 1 : 0
              last_date = dates.date(row)
              rows += 1
            end
          end
        else
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
      end
      raise "wrong count" unless rows == count
      rate = rows / elapsed.total_seconds
      rates[reader] << rate
      puts "#{reader} N=#{count} seconds=#{elapsed.total_seconds.round(6)} rows/s=#{rate.round.to_i64} checksum=#{checksum} double=#{floats.to_i64} date=#{last_date}"
    end
  end
end
rates.each { |reader, samples| puts "#{reader} N=#{count} median_rows/s=#{samples.sort[samples.size // 2].round.to_i64}" }
