require "../spec_helper"
require "../support/lifecycle"

describe "DuckDB correctness" do
  it "opens IN_MEMORY without creating a file" do
    DB.connect DuckDB::IN_MEMORY do |cnn|
      cnn.exec "CREATE TABLE memory_only (i INTEGER)"
      File.exists?("[:memory:]").should be_false
      File.exists?(":memory:").should be_false
    end
  ensure
    File.delete?("[:memory:]")
  end

  it "isolates separate IN_MEMORY connections" do
    DB.connect DuckDB::IN_MEMORY do |first|
      first.exec "CREATE TABLE memory_isolation (i INTEGER)"
      DB.connect DuckDB::IN_MEMORY do |second|
        second.scalar("SELECT count(*) FROM information_schema.tables WHERE table_name = 'memory_isolation'").should eq(0)
      end
    end
  ensure
    File.delete?("[:memory:]")
  end

  it "keeps both relative file URI forms working" do
    ["duckdb:./.tmp/uri_plain.db", "duckdb://./.tmp/uri_host.db"].each do |uri|
      filename = uri.ends_with?("uri_plain.db") ? ".tmp/uri_plain.db" : ".tmp/uri_host.db"
      begin
        DB.connect(uri) { |cnn| cnn.exec "CREATE TABLE persisted (i INTEGER)" }
        File.exists?(filename).should be_true
        DB.connect(uri) { |cnn| cnn.scalar("SELECT count(*) FROM persisted").should eq(0) }
      ensure
        File.delete?(filename)
      end
    end
  end

  it "raises DuckDB's error for a failing unprepared exec" do
    with_cnn do |cnn|
      expect_raises(DuckDB::Exception, /Conversion Error/) do
        cnn.unprepared.exec "SELECT CAST('bad' AS INTEGER)"
      end
    end
  end

  it "destroys results from successful and failing unprepared execs" do
    with_cnn do |cnn|
      before = NativeLifetime.results
      cnn.unprepared.exec("SELECT 42").rows_affected.should eq(0)
      begin
        cnn.unprepared.exec "SELECT CAST('bad' AS INTEGER)"
      rescue DuckDB::Exception
      end
      NativeLifetime.results.should eq(before)
    end
  end

  it "destroys prepared exec results and preserves rows affected" do
    with_cnn do |cnn|
      cnn.exec "CREATE TABLE affected (i INTEGER)"
      before = NativeLifetime.results
      cnn.exec("INSERT INTO affected VALUES (?), (?)", 1, 2).rows_affected.should eq(2)
      NativeLifetime.results.should eq(before)
    end
  end

  it "destroys results when prepared execution fails" do
    with_cnn do |cnn|
      before = NativeLifetime.results
      expect_raises(DuckDB::Exception, /Conversion Error/) do
        cnn.exec "SELECT CAST(? AS INTEGER)", "bad"
      end
      NativeLifetime.results.should eq(before)
      expect_raises(DuckDB::Exception, /Conversion Error/) do
        cnn.query("SELECT CAST(? AS INTEGER)", "bad") { |_| }
      end
      NativeLifetime.results.should eq(before)
    end
  end

  it "destroys results when unprepared query execution fails" do
    with_cnn do |cnn|
      before = NativeLifetime.results
      expect_raises(DuckDB::Exception, /Conversion Error/) do
        cnn.unprepared.query("SELECT CAST('bad' AS INTEGER)") { |_| }
      end
      NativeLifetime.results.should eq(before)
    end
  end

  it "raises DuckDB's error and destroys a failed prepare" do
    with_cnn do |cnn|
      before = NativeLifetime.statements
      expect_raises(DuckDB::Exception, /Parser Error/) do
        cnn.prepared "SELEC broken syntax"
      end
      NativeLifetime.statements.should eq(before)
    end
  end

  it "reads an untyped SQL NULL and advances to the next column" do
    with_cnn do |cnn|
      cnn.scalar("SELECT NULL").should be_nil
      cnn.query "SELECT NULL, NULL" do |rs|
        rs.move_next.should be_true
        rs.read.should be_nil
        rs.read.should be_nil
      end
    end
  end

  it "reads empty strings and multibyte strings" do
    with_cnn do |cnn|
      cnn.scalar("SELECT 'Grüße'").should eq("Grüße")
      cnn.scalar("SELECT ''").should eq("")
    end
  end

  it "reads embedded NUL bytes from VARCHAR" do
    with_cnn do |cnn|
      cnn.scalar("SELECT 'a' || chr(0) || 'b'").should eq("a\0b")
    end
  end

  it "reads typed columns next to SQLNULL" do
    with_cnn do |cnn|
      cnn.query "SELECT NULL, 42" do |rs|
        rs.move_next.should be_true
        rs.read.should be_nil
        rs.read.should eq(42)
      end
    end
  end

  it "round trips embedded NUL bytes through a prepared insert" do
    with_cnn do |cnn|
      cnn.exec "CREATE TABLE nul_strings (s VARCHAR)"
      cnn.exec "INSERT INTO nul_strings VALUES (?)", "a\0b"
      # encode() exposes the stored bytes without DuckDB's lossy legacy VARCHAR accessor.
      cnn.scalar("SELECT encode(s) FROM nul_strings").should eq("a\0b".to_slice)
    end
  end

  it "round trips embedded NUL bytes through an appender" do
    with_cnn do |cnn|
      cnn.exec "CREATE TABLE nul_strings (s VARCHAR)"
      cnn.appender("nul_strings") { |appender| appender.row { |row| row << "a\0b" } }
      cnn.scalar("SELECT encode(s) FROM nul_strings").should eq("a\0b".to_slice)
    end
  end

  it "destroys an appender on close and allows repeated close" do
    with_cnn do |cnn|
      cnn.exec "CREATE TABLE appender_close (i INTEGER)"
      before = NativeLifetime.appenders
      appender = cnn.appender("appender_close")
      appender.row { |row| row << 42 }
      appender.close
      appender.close
      NativeLifetime.appenders.should eq(before)
      cnn.scalar("SELECT i FROM appender_close").should eq(42)
    end
  end

  it "closes and destroys an appender when its block raises" do
    with_cnn do |cnn|
      cnn.exec "CREATE TABLE appender_ensure (i INTEGER)"
      before = NativeLifetime.appenders
      expect_raises(Exception, "block failed") do
        cnn.appender("appender_ensure") do |appender|
          appender.row { |row| row << 42 }
          raise "block failed"
        end
      end
      NativeLifetime.appenders.should eq(before)
      cnn.scalar("SELECT i FROM appender_ensure").should eq(42)
    end
  end

  it "destroys an appender even when close fails" do
    with_cnn do |cnn|
      cnn.exec "CREATE TABLE appender_constraint (i INTEGER NOT NULL)"
      before = NativeLifetime.appenders
      appender = cnn.appender("appender_constraint")
      appender.row { |row| row << nil }
      expect_raises(DuckDB::Exception) { appender.close }
      appender.close
      NativeLifetime.appenders.should eq(before)
    end
  end

  it "destroys the handle from a failed appender creation" do
    with_cnn do |cnn|
      before = NativeLifetime.appenders
      expect_raises(DuckDB::Exception) { cnn.appender("missing_table") }
      NativeLifetime.appenders.should eq(before)
    end
  end

  it "filters every crystal-db parameter by exact name" do
    keys = %w(initial_pool_size max_pool_size max_idle_pool_size checkout_timeout retry_attempts retry_delay prepared_statements prepared_statements_cache)
    query = keys.map { |key| "#{key}=1" }.join('&')
    options = DuckDB::Connection::Options.from_uri(URI.parse("#{DuckDB::IN_MEMORY}?#{query}&pool_size=2&threads=1"))
    options.config_params.should eq({"pool_size" => "2", "threads" => "1"})
  end

  it "destroys open appenders before closing their connection" do
    before = NativeLifetime.appenders
    cnn = DB.connect("duckdb::memory:").as(DuckDB::Connection)
    cnn.exec "CREATE TABLE connection_close (i INTEGER)"
    appender = cnn.appender("connection_close")
    appender.row { |row| row << 42 }
    cnn.close
    NativeLifetime.appenders.should eq(before)
    appender.close
    expect_raises(DuckDB::Exception, "Appender is closed") { appender << 1 }
  ensure
    cnn.try &.close
  end

  it "releases a query's connection back to its pool" do
    with_db "max_pool_size=1&checkout_timeout=0.01" do |db|
      db.scalar("SELECT 42").should eq(42)
      db.pool.stats.idle_connections.should eq(1)
      db.scalar("SELECT 43").should eq(43)
    end
  end

  it "frees the error message from a failed configured open" do
    before = NativeLifetime.open_errors
    expect_raises(DuckDB::Exception, /IO Error/) do
      DB.connect "duckdb:./.tmp/missing-read-only.db?access_mode=read_only"
    end
    NativeLifetime.open_errors.should eq(before)
  end

  it "destroys uncached statements after exec and failed queries" do
    DB.connect "duckdb::memory:?prepared_statements_cache=false" do |cnn|
      before = NativeLifetime.statements
      cnn.exec "SELECT ?::INTEGER", 42
      NativeLifetime.statements.should eq(before)
      expect_raises(DuckDB::Exception) { cnn.exec "SELECT ?::INTEGER", "bad" }
      NativeLifetime.statements.should eq(before)
      expect_raises(DuckDB::Exception) { cnn.query("SELECT ?::INTEGER", "bad") { |_| } }
      NativeLifetime.statements.should eq(before)
    end
  end
end
