require "../spec_helper"
require "../support/lifecycle"

private def streaming_handles
  {NativeLifetime.results, NativeLifetime.statements, NativeLifetime.chunks, NativeLifetime.logical_types}
end

describe "DuckDB streaming" do
  it "is opt-in through a filtered URI parameter or a connection property" do
    options = DuckDB::Connection::Options.from_uri(URI.parse("duckdb::memory:?stream_results=true&threads=1"))
    options.stream_results.should be_true
    options.config_params.should eq({"threads" => "1"})
    DB.connect "duckdb::memory:" do |cnn|
      connection = cnn.as(DuckDB::Connection)
      connection.stream_results.should be_false
      calls = NativeLifetime.streaming_executions
      cnn.scalar("SELECT 42").should eq(42)
      NativeLifetime.streaming_executions.should eq(calls)
      connection.stream_results = true
      cnn.scalar("SELECT 43").should eq(43)
      NativeLifetime.streaming_executions.should eq(calls + 1)
      cnn.unprepared.scalar("SELECT 44").should eq(44)
      NativeLifetime.streaming_executions.should eq(calls + 2)
      cnn.exec("SELECT 45")
      NativeLifetime.streaming_executions.should eq(calls + 2)
    end
  end

  it "surfaces a late query error during iteration and frees every handle" do
    DB.connect "duckdb::memory:?stream_results=true&threads=1&prepared_statements_cache=false" do |cnn|
      before = streaming_handles
      # Exceed 2.0's 10 MiB prefetch buffer so some rows arrive before failure.
      rs = cnn.query("SELECT CASE WHEN i = 5000000 THEN error('boom') ELSE i END FROM range(10000000) t(i)")
      rows = 0_i64
      last = -1_i64
      expect_raises(DuckDB::Exception, /boom/) do
        rs.each { last = rs.read(Int64); rows += 1 }
      end
      rows.should be > 0
      rows.should be <= 5000000
      last.should eq(rows - 1)
      rs.closed?.should be_true
      streaming_handles.should eq(before)
      cnn.scalar("SELECT 42").should eq(42)
    ensure
      rs.try &.close
    end
  end

  it "blocks prepared, cached and unprepared second queries until the stream closes" do
    DB.connect "duckdb::memory:?stream_results=true" do |cnn|
      cached = cnn.prepared("SELECT ?::INTEGER")
      rs = cnn.query("SELECT i FROM range(100000) t(i)")
      rs.move_next.should be_true
      rs.read(Int64).should eq(0)
      expect_raises(DuckDB::Exception, /active streaming result/) { cnn.scalar("SELECT 7") }
      expect_raises(DuckDB::Exception, /active streaming result/) { cached.scalar(7) }
      expect_raises(DuckDB::Exception, /active streaming result/) { cnn.unprepared.exec("SELECT 7") }
      expect_raises(DuckDB::Exception, /active streaming result/) { cnn.unprepared.query("SELECT 7") { |_| } }
      cnn.as(DuckDB::Connection).stream_results = false
      expect_raises(DuckDB::Exception, /active streaming result/) { cnn.exec("SELECT 7") }
      # The rejected second queries must leave the stream intact.
      rs.move_next.should be_true
      rs.read(Int64).should eq(1)
      rs.close
      cached.scalar(7).should eq(7)
    ensure
      rs.try &.close
    end
  end

  it "allows another query after exhaustion while the old result is still open" do
    DB.connect "duckdb::memory:?stream_results=true" do |cnn|
      rs = cnn.query("SELECT i FROM range(5000) t(i)")
      rows = 0
      rs.each { rs.read(Int64); rows += 1 }
      rows.should eq(5000)
      cnn.scalar("SELECT 42").should eq(42)
      rs.move_next.should be_false
      rs.close
    ensure
      rs.try &.close
    end
  end

  it "releases streams and their statements when closing the connection" do
    before = streaming_handles
    cnn = DB.connect("duckdb::memory:?stream_results=true&prepared_statements_cache=false")
    rs = cnn.query("SELECT i FROM range(100000) t(i)")
    rs.move_next
    cnn.close
    rs.closed?.should be_true
    streaming_handles.should eq(before)
  ensure
    rs.try &.close
    cnn.try &.close
  end
end

describe "DuckDB streaming pool bookkeeping" do
  it "releases a one-connection pool after prepared and unprepared streams" do
    DB.open "duckdb::memory:?stream_results=true&max_pool_size=1&checkout_timeout=0.01&prepared_statements_cache=false" do |db|
      2.times do
        db.scalar("SELECT 42").should eq(42)
        db.pool.stats.idle_connections.should eq(1)
        db.unprepared.scalar("SELECT 43").should eq(43)
        db.pool.stats.idle_connections.should eq(1)
      end
    end
  end
end
