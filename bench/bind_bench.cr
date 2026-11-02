require "../src/duckdb"

# A cached four-column INSERT through crystal-db, with fixed prebuilt scalar
# values and one transaction per run. Defaults: 200,000 executions, 5 repeats.
# Modes: insert, metadata (two logical-type lookups/checks per iteration), all.
# Rotate separately built driver variants externally to control run-order noise.
# master predates the driver's param_logical_type declaration. Use the exact
# common ABI here so this same program can measure all three source snapshots.
module DuckDB
  lib LibDuckDB
    fun param_logical_type = duckdb_param_logical_type(statement : PreparedStatement, index : Idx) : LogicalType
  end
end

iterations = (ARGV[0]? || "200000").to_i
repeats = (ARGV[1]? || "5").to_i
mode = ARGV[2]? || "all"
raise "positive iterations and repeats required" unless iterations > 0 && repeats > 0
raise "mode must be insert, metadata or all" unless {"insert", "metadata", "all"}.includes?(mode)

DB.connect "duckdb::memory:?threads=1" do |cnn|
  puts "duckdb=#{cnn.scalar("SELECT version()")} executions=#{iterations} repeats=#{repeats} mode=#{mode} transaction=single"
  cnn.exec "CREATE TABLE t (id BIGINT, ts TIMESTAMP, amount DECIMAL(18,3), label VARCHAR)"
  sql = "INSERT INTO t VALUES (?, ?, ?, ?)"
  timestamp = DuckDB::Timestamp.new(Time.utc(2026, 1, 2, 3, 4, 5, nanosecond: 123456000))
  decimal = DuckDB::Decimal.new(123456_i128, 18, 3)
  label = "bind-bench"
  # Exercise the same crystal-db cached #exec path used by ordinary INSERT loops.
  cnn.exec "BEGIN"
  1000.times { |i| cnn.exec(sql, i.to_i64, timestamp, decimal, label) }
  cnn.exec "ROLLBACK"

  if mode == "insert" || mode == "all"
    repeats.times do |repeat|
      cnn.exec "BEGIN"
      GC.collect
      start = Time.monotonic
      iterations.times { |i| cnn.exec(sql, i.to_i64, timestamp, decimal, label) }
      seconds = (Time.monotonic - start).total_seconds
      # Count and checksums are outside the measured region; rollback bounds storage.
      count = cnn.scalar("SELECT count(*) FROM t").as(Int64)
      checksum = cnn.scalar("SELECT sum(id)::BIGINT FROM t").as(Int64)
      raise "insert count/checksum mismatch" unless count == iterations && checksum == iterations.to_i64 * (iterations - 1) // 2
      cnn.exec "ROLLBACK"
      puts "insert run=#{repeat + 1} executions=#{iterations} seconds=#{seconds} rows_per_second=#{iterations / seconds} checksum=#{checksum}"
    end
  end

  if mode == "metadata" || mode == "all"
    statement = cnn.prepared(sql).as(DuckDB::Statement)
    repeats.times do |repeat|
      GC.collect
      checksum = 0_i64
      start = Time.monotonic
      iterations.times do
        ts_type = DuckDB::LibDuckDB.param_logical_type(statement.to_unsafe, 2_u64)
        begin
          id = DuckDB::LibDuckDB.get_type_id(ts_type)
          raise "timestamp metadata mismatch" unless id.timestamp?
          raise "timestamp precision loss" unless timestamp.nanoseconds % 1000 == 0
          checksum += id.value
        ensure
          DuckDB::LibDuckDB.destroy_logical_type(pointerof(ts_type))
        end
        decimal_type = DuckDB::LibDuckDB.param_logical_type(statement.to_unsafe, 3_u64)
        begin
          id = DuckDB::LibDuckDB.get_type_id(decimal_type)
          scale = DuckDB::LibDuckDB.decimal_scale(decimal_type)
          raise "decimal metadata mismatch" unless id.decimal? && scale == 3
          if decimal.scale > scale && decimal.value % (10_i128 ** (decimal.scale - scale)) != 0
            raise "decimal precision loss"
          end
          checksum += id.value + scale
        ensure
          DuckDB::LibDuckDB.destroy_logical_type(pointerof(decimal_type))
        end
      end
      seconds = (Time.monotonic - start).total_seconds
      puts "metadata run=#{repeat + 1} iterations=#{iterations} seconds=#{seconds} ns_per_checked_pair=#{seconds * 1e9 / iterations} checksum=#{checksum}"
    end
  end
end
