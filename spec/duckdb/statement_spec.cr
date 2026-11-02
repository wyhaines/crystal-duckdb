require "../spec_helper"
require "../support/lifecycle"

describe "DuckDB statement correctness" do
  it "reuses cached statements with new bindings and rejects missing or extra arguments" do
    with_cnn do |cnn|
      sql = "SELECT ?::INTEGER + ?::INTEGER"
      cnn.scalar(sql, 10, 20).should eq(30)
      expect_raises(DuckDB::Exception, /Expected 2 arguments, got 1/) { cnn.scalar(sql, 99) }
      expect_raises(DuckDB::Exception, /Expected 2 arguments, got 3/) { cnn.exec(sql, 1, 2, 3) }
      cnn.scalar(sql, 3, 4).should eq(7)
      statement = cnn.prepared(sql)
      statement.scalar(5, 6).should eq(11)
      statement.scalar(7, 8).should eq(15)
    end
  end

  it "rejects re-execution with an open result and resumes after closing it" do
    with_cnn do |cnn|
      statement = cnn.prepared("SELECT ?::INTEGER")
      rs = statement.query(1)
      expect_raises(DuckDB::Exception, /previous result/) { statement.query(2) }
      expect_raises(DuckDB::Exception, /previous result/) { statement.exec(2) }
      rs.move_next.should be_true
      rs.read(Int32).should eq(1)
      rs.close
      statement.scalar(2).should eq(2)
    ensure
      rs.try &.close
    end
  end

  it "allows nested materialized queries from different statements" do
    with_cnn do |cnn|
      cnn.query("SELECT i FROM range(5000) t(i)") do |rs|
        5000.times do |i|
          rs.move_next.should be_true
          rs.read(Int64).should eq(i)
          cnn.scalar("SELECT 42").should eq(42) if i == 0 || i == 3000
        end
      end
    end
  end

  it "closes an active result when its statement is explicitly closed" do
    before = NativeLifetime.statements
    with_cnn do |cnn|
      statement = cnn.build_prepared_statement("SELECT 42")
      rs = statement.query
      rs.move_next
      statement.close
      rs.closed?.should be_true
      expect_raises(DuckDB::Exception, /Statement is closed/) { statement.query }
    end
    NativeLifetime.statements.should eq(before)
  end

  it "releases uncached statements after successful query blocks" do
    DB.connect "duckdb::memory:?prepared_statements_cache=false" do |cnn|
      before = NativeLifetime.statements
      2.times do
        cnn.scalar("SELECT 42").should eq(42)
        cnn.unprepared.scalar("SELECT 43").should eq(43)
        NativeLifetime.statements.should eq(before)
      end
    end
  end

  it "rejects NUL bytes in prepared and unprepared SQL before making a native call" do
    with_cnn do |cnn|
      before = {NativeLifetime.results, NativeLifetime.statements}
      ["SELECT 12\0 +30", "\0SELECT 42"].each do |sql|
        expect_raises(DuckDB::Exception, /SQL text contains a NUL/) { cnn.scalar(sql) }
        expect_raises(DuckDB::Exception, /SQL text contains a NUL/) { cnn.exec(sql) }
        expect_raises(DuckDB::Exception, /SQL text contains a NUL/) { cnn.unprepared.scalar(sql) }
        expect_raises(DuckDB::Exception, /SQL text contains a NUL/) { cnn.unprepared.exec(sql) }
      end
      {NativeLifetime.results, NativeLifetime.statements}.should eq(before)
    end
  end

  it "reports zero last_insert_id and preserves affected row counts" do
    with_cnn do |cnn|
      cnn.exec "CREATE SEQUENCE ids START 100"
      cnn.exec "CREATE TABLE insert_ids (i BIGINT DEFAULT nextval('ids'))"
      [cnn.exec("INSERT INTO insert_ids DEFAULT VALUES"), cnn.unprepared.exec("INSERT INTO insert_ids DEFAULT VALUES")].each do |result|
        result.rows_affected.should eq(1)
        result.last_insert_id.should eq(0)
      end
      cnn.scalar("SELECT min(i) FROM insert_ids").should eq(100)
    end
  end

  it "raises a useful DuckDB exception when a bind fails without a prepare error" do
    DB.connect "duckdb::memory:?prepared_statements_cache=false" do |cnn|
      before = NativeLifetime.statements
      invalid = String.new(Bytes[0xff, 0xfe])
      expect_raises(DuckDB::Exception, /bind parameters.*UTF-8/) { cnn.scalar("SELECT ?::VARCHAR", invalid) }
      NativeLifetime.statements.should eq(before)
      cnn.scalar("SELECT ?::VARCHAR", "ok").should eq("ok")
    end
  end
end

describe "DuckDB result pool ownership" do
  it "keeps the connection checked out when a second execution is rejected" do
    with_db "max_pool_size=1&checkout_timeout=0.01" do |db|
      rs = db.query("SELECT ?::INTEGER", 1)
      statement = rs.statement
      expect_raises(DuckDB::Exception, /previous result/) { statement.query(2) }
      db.pool.stats.idle_connections.should eq(0)
      rs.close
      db.pool.stats.idle_connections.should eq(1)
    end
  end
end
