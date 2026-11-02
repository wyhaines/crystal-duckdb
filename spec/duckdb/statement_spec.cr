require "../spec_helper"
require "../support/lifecycle"

private def walk_statement_nodes(cnn : DuckDB::Connection, id : Int64, rows : Array(Int64)) : Nil
  cnn.query("SELECT id FROM statement_nodes WHERE parent = ? ORDER BY id", id) do |rs|
    rs.each do
      child = rs.read(Int64)
      rows << child
      walk_statement_nodes(cnn, child, rows)
    end
  end
end

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

  it "reads two interleaved materialized results from one cached statement" do
    with_cnn do |cnn|
      sql = "SELECT i + ?::BIGINT FROM range(5000) t(i)"
      first = cnn.query(sql, 10_i64)
      second = cnn.query(sql, 20_i64)
      second.statement.should be(first.statement)
      # Exec must also leave both materialized results intact.
      first.statement.exec(30_i64)
      5000.times do |i|
        first.move_next.should be_true
        first.read(Int64).should eq(i + 10)
        second.move_next.should be_true
        second.read(Int64).should eq(i + 20)
      end
      first.close
      second.closed?.should be_false
      second.move_next.should be_false
      second.close
    ensure
      first.try &.close
      second.try &.close
    end
  end

  it "reuses the same cached SQL through a recursive walk at depth four" do
    with_cnn do |cnn|
      cnn.exec "CREATE TABLE statement_nodes (id BIGINT, parent BIGINT)"
      cnn.exec "INSERT INTO statement_nodes VALUES (1, 0), (2, 0), (3, 1), (4, 1), (5, 3), (6, 5), (7, 2), (8, 7), (9, 8)"
      rows = [] of Int64
      walk_statement_nodes(cnn, 0_i64, rows)
      rows.should eq([1_i64, 3, 5, 6, 4, 2, 7, 8, 9])
    end
  end

  it "keeps older materialized results readable after a later execution fails" do
    DB.connect "duckdb::memory:?prepared_statements_cache=false" do |cnn|
      before = native_lifetime { NativeLifetime.statements }
      rs = cnn.query("SELECT ?::INTEGER", 42)
      expect_raises(DuckDB::Exception, /Conversion Error/) { rs.statement.query("bad") }
      rs.move_next.should be_true
      rs.read(Int32).should eq(42)
      rs.close
      native_lifetime { NativeLifetime.statements.should eq(before) }
    ensure
      rs.try &.close
    end
  end

  it "closes an auto-closing statement only after its last result closes" do
    with_cnn do |cnn|
      before = native_lifetime { NativeLifetime.statements }
      statement = cnn.build_prepared_statement("SELECT ?::INTEGER")
      statement.auto_close = true
      first = statement.query(1)
      second = statement.query(2)
      first.close
      statement.closed?.should be_false
      statement.exec(3)
      statement.closed?.should be_false
      second.move_next.should be_true
      second.read(Int32).should eq(2)
      second.close
      statement.closed?.should be_true
      native_lifetime { NativeLifetime.statements.should eq(before) }
    ensure
      statement.try &.close
    end
  end

  it "still rejects the same cached SQL while a streaming result is active" do
    DB.connect "duckdb::memory:?stream_results=true" do |cnn|
      rs = cnn.query("SELECT ?::BIGINT FROM range(100000)", 1_i64)
      expect_raises(DuckDB::Exception, /active streaming result/) { rs.statement.query(2_i64) }
      expect_raises(DuckDB::Exception, /active streaming result/) { rs.statement.exec(2_i64) }
      rs.move_next.should be_true
      rs.read(Int64).should eq(1)
      statement = rs.statement
      rs.close
      statement.scalar(2_i64).should eq(2)
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

  it "closes every open result when its statement is explicitly closed" do
    before = native_lifetime { {NativeLifetime.statements, NativeLifetime.results, NativeLifetime.chunks, NativeLifetime.logical_types} }
    with_cnn do |cnn|
      statement = cnn.build_prepared_statement("SELECT ?::INTEGER")
      results = [statement.query(1), statement.query(2), statement.query(3)]
      results[0].move_next
      results[1].move_next
      statement.close
      results.each { |rs| rs.closed?.should be_true }
      expect_raises(DuckDB::Exception, /Statement is closed/) { statement.query(4) }
    ensure
      statement.try &.close
    end
    native_lifetime { {NativeLifetime.statements, NativeLifetime.results, NativeLifetime.chunks, NativeLifetime.logical_types}.should eq(before) }
  end

  it "releases uncached statements after successful query blocks" do
    DB.connect "duckdb::memory:?prepared_statements_cache=false" do |cnn|
      before = native_lifetime { NativeLifetime.statements }
      2.times do
        cnn.scalar("SELECT 42").should eq(42)
        cnn.unprepared.scalar("SELECT 43").should eq(43)
        native_lifetime { NativeLifetime.statements.should eq(before) }
      end
    end
  end

  it "rejects NUL bytes in prepared and unprepared SQL before making a native call" do
    with_cnn do |cnn|
      before = native_lifetime { {NativeLifetime.results, NativeLifetime.statements} }
      ["SELECT 12\0 +30", "\0SELECT 42"].each do |sql|
        expect_raises(DuckDB::Exception, /SQL text contains a NUL/) { cnn.scalar(sql) }
        expect_raises(DuckDB::Exception, /SQL text contains a NUL/) { cnn.exec(sql) }
        expect_raises(DuckDB::Exception, /SQL text contains a NUL/) { cnn.unprepared.scalar(sql) }
        expect_raises(DuckDB::Exception, /SQL text contains a NUL/) { cnn.unprepared.exec(sql) }
      end
      native_lifetime { {NativeLifetime.results, NativeLifetime.statements}.should eq(before) }
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
      before = native_lifetime { NativeLifetime.statements }
      invalid = String.new(Bytes[0xff, 0xfe])
      expect_raises(DuckDB::Exception, /bind parameters.*UTF-8/) { cnn.scalar("SELECT ?::VARCHAR", invalid) }
      native_lifetime { NativeLifetime.statements.should eq(before) }
      cnn.scalar("SELECT ?::VARCHAR", "ok").should eq("ok")
    end
  end
end

describe "DuckDB result pool ownership" do
  it "keeps the connection checked out until all results from one statement close" do
    with_db "max_pool_size=1&checkout_timeout=0.01" do |db|
      rs = db.query("SELECT ?::INTEGER", 1)
      statement = rs.statement
      second = statement.query(2)
      db.pool.stats.idle_connections.should eq(0)
      rs.close
      db.pool.stats.idle_connections.should eq(0)
      second.move_next.should be_true
      second.read(Int32).should eq(2)
      second.close
      db.pool.stats.idle_connections.should eq(1)
    end
  end
end
