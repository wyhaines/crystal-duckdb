require "../spec_helper"
require "../support/lifecycle"

private def with_instance_file(&)
  path = ".tmp/instances-#{Random.rand(1_u64..UInt64::MAX)}.db"
  yield path, "duckdb:#{path}"
ensure
  if path
    File.delete?(path)
    File.delete?("#{path}.wal")
  end
end

private def native_owners
  {NativeLifetime.databases, NativeLifetime.connections, NativeLifetime.caches, NativeLifetime.open_errors}
end

describe "DuckDB database instances" do
  it "shares committed writes between simultaneous checkouts on a file" do
    with_instance_file do |path, uri|
      DB.open "#{uri}?max_pool_size=2" do |db|
        a = db.checkout
        b = db.checkout
        begin
          a.exec "CREATE TABLE shared (v BIGINT)"
          a.exec "INSERT INTO shared VALUES (10)"
          b.scalar("SELECT v FROM shared").should eq(10_i64)
          b.exec "UPDATE shared SET v=20"
          a.scalar("SELECT v FROM shared").should eq(20_i64)
        ensure
          a.release
          b.release
        end
      end
    end
  end

  it "preserves both committed updates from the audit after reopening" do
    with_instance_file do |path, uri|
      DB.connect uri do |cnn|
        cnn.exec "CREATE TABLE t (id INT PRIMARY KEY, v BIGINT)"
        cnn.exec "INSERT INTO t VALUES (1,0),(2,0)"
      end
      DB.open uri do |a|
        DB.open uri do |b|
          a.scalar("SELECT sum(v) FROM t").should eq(0_i64)
          b.scalar("SELECT sum(v) FROM t").should eq(0_i64)
          a.exec "UPDATE t SET v=10 WHERE id=1"
          b.exec "UPDATE t SET v=20 WHERE id=2"
        end
      end
      DB.open(uri) { |db| db.query_all("SELECT v FROM t ORDER BY id", as: Int64).should eq([10_i64, 20_i64]) }
    end
  end

  it "shares a file across pools, standalone connections and equivalent paths" do
    with_instance_file do |path, uri|
      DB.open uri do |a|
        DB.open "duckdb:#{File.expand_path(path)}" do |b|
          a.exec "CREATE TABLE shared (v BIGINT)"
          b.exec "INSERT INTO shared VALUES (42)"
          DB.connect(uri) { |cnn| cnn.scalar("SELECT v FROM shared").should eq(42_i64) }
          a.scalar("SELECT v FROM shared").should eq(42_i64)
        end
      end
    end
  end

  it "shares each anonymous memory pool but isolates different pools" do
    ["duckdb://", DuckDB::IN_MEMORY, "duckdb::memory:"].each do |uri|
      DB.open uri do |a|
        first = a.checkout
        second = a.checkout
        begin
          first.exec "CREATE TABLE shared (v BIGINT)"
          first.exec "INSERT INTO shared VALUES (42)"
          second.scalar("SELECT v FROM shared").should eq(42_i64)
          DB.open uri do |b|
            b.scalar("SELECT count(*) FROM information_schema.tables WHERE table_name='shared'").should eq(0_i64)
          end
        ensure
          first.release
          second.release
        end
      end
    end
  end

  it "retains an anonymous memory database while its pool has zero connections" do
    before = native_owners
    DB.open "#{DuckDB::IN_MEMORY}?initial_pool_size=0&max_idle_pool_size=0" do |db|
      db.exec "CREATE TABLE retained AS SELECT 42::BIGINT v"
      db.pool.stats.open_connections.should eq(0)
      NativeLifetime.databases.should eq(before[0] + 1)
      NativeLifetime.connections.should eq(before[1])
      db.scalar("SELECT v FROM retained").should eq(42_i64)
    end
    native_owners.should eq(before)
  end

  it "shares named memory databases through the cache and releases their contents" do
    uri = "duckdb::memory:driver_named"
    before = native_owners
    DB.open uri do |a|
      DB.open "duckdb://%3Amemory%3Adriver_named" do |b|
        a.exec "CREATE TABLE named AS SELECT 42::BIGINT v"
        b.scalar("SELECT v FROM named").should eq(42_i64)
      end
      a.scalar("SELECT v FROM named").should eq(42_i64)
    end
    native_owners.should eq(before)
    DB.open(uri) { |db| db.scalar("SELECT count(*) FROM information_schema.tables WHERE table_name='named'").should eq(0_i64) }
  end

  it "rejects a different configuration with DuckDB's message and frees its error" do
    with_instance_file do |path, uri|
      before = native_owners
      DB.open "#{uri}?threads=1" do |a|
        current = native_owners
        expect_raises(DuckDB::Exception, /different configuration/) { DB.open("#{uri}?threads=2") }
        native_owners.should eq(current)
        DB.open("#{uri}?threads=1") { |b| b.scalar("SELECT 42").should eq(42) }
      end
      native_owners.should eq(before)
      DB.open("#{uri}?threads=2") { |db| db.scalar("SELECT current_setting('threads')").should eq(2_i64) }
    end
  end

  it "closes all checked out and idle handles and destroys the last cache" do
    with_instance_file do |path, uri|
      before = native_owners
      a = DB.open("#{uri}?initial_pool_size=3&max_idle_pool_size=3")
      b = DB.open(uri)
      a.exec "CREATE TABLE persisted AS SELECT 42::BIGINT v"
      checked_out = a.checkout
      a.close
      a.close
      checked_out.closed?.should be_true
      NativeLifetime.databases.should eq(before[0] + 1)
      NativeLifetime.connections.should eq(before[1] + 1)
      b.scalar("SELECT v FROM persisted").should eq(42_i64)
      b.close
      native_owners.should eq(before)
      DB.open(uri) { |db| db.scalar("SELECT v FROM persisted").should eq(42_i64) }
      native_owners.should eq(before)
      # A read-only open has different native config: it succeeds only after the
      # last writer has released the file's cached instance.
      DB.open("#{uri}?access_mode=read_only") { |db| db.scalar("SELECT v FROM persisted").should eq(42_i64) }
    ensure
      a.try &.close
      b.try &.close
    end
  end

  it "releases a file even while another database keeps the shared cache alive" do
    with_instance_file do |path, uri|
      with_instance_file do |other_path, other_uri|
        before = native_owners
        DB.open other_uri do |other|
          DB.open(uri) { |db| db.exec "CREATE TABLE persisted AS SELECT 42::BIGINT v" }
          NativeLifetime.caches.should eq(before[2] + 1)
          DB.open "#{uri}?access_mode=read_only" do |db|
            db.scalar("SELECT v FROM persisted").should eq(42_i64)
          end
        end
        native_owners.should eq(before)
      end
    end
  end

  it "keeps one owner for connections made by the same builder" do
    before = native_owners
    builder = DuckDB::Driver.new.connection_builder(URI.parse(DuckDB::IN_MEMORY))
    first = builder.build
    second = builder.build
    first.exec "CREATE TABLE shared AS SELECT 42::BIGINT v"
    NativeLifetime.databases.should eq(before[0] + 1)
    first.close
    second.scalar("SELECT v FROM shared").should eq(42_i64)
    second.close
    native_owners.should eq(before)
  ensure
    first.try &.close
    second.try &.close
  end

  it "closes the owner of a standalone connection" do
    before = native_owners
    cnn = DB.connect(DuckDB::IN_MEMORY)
    NativeLifetime.databases.should eq(before[0] + 1)
    NativeLifetime.connections.should eq(before[1] + 1)
    cnn.close
    cnn.close
    native_owners.should eq(before)
  ensure
    cnn.try &.close
  end

  it "creates connections concurrently from fibers without splitting a memory pool" do
    before = native_owners
    DB.open "#{DuckDB::IN_MEMORY}?initial_pool_size=0&max_idle_pool_size=0&max_pool_size=8" do |db|
      db.exec "CREATE TABLE concurrent (v BIGINT)"
      ready = Channel(Nil).new(8)
      go = Channel(Nil).new(8)
      done = Channel(::Exception?).new(8)
      8.times do |i|
        spawn do
          announced = false
          begin
            db.using_connection do |cnn|
              ready.send(nil)
              announced = true
              go.receive
              cnn.exec "INSERT INTO concurrent VALUES (?)", i.to_i64
            end
            done.send(nil)
          rescue ex
            ready.send(nil) unless announced
            done.send(ex)
          end
        end
      end
      8.times { ready.receive }
      8.times { go.send(nil) }
      8.times { done.receive.should be_nil }
      db.scalar("SELECT count(*) FROM concurrent").should eq(8_i64)
    end
    native_owners.should eq(before)
  end

  it "opens the same cached file concurrently from fibers" do
    with_instance_file do |path, uri|
      before = native_owners
      DB.connect(uri) { |cnn| cnn.exec "CREATE TABLE concurrent (v BIGINT)" }
      ready = Channel(Nil).new(8)
      go = Channel(Nil).new(8)
      done = Channel(::Exception?).new(8)
      8.times do |i|
        spawn do
          announced = false
          begin
            DB.open uri do |db|
              ready.send(nil)
              announced = true
              go.receive
              db.exec "INSERT INTO concurrent VALUES (?)", i.to_i64
            end
            done.send(nil)
          rescue ex
            ready.send(nil) unless announced
            done.send(ex)
          end
        end
      end
      8.times { ready.receive }
      8.times { go.send(nil) }
      8.times { done.receive.should be_nil }
      native_owners.should eq(before)
      DB.open(uri) { |db| db.scalar("SELECT count(*) FROM concurrent").should eq(8_i64) }
    end
  end

  it "releases a failed standalone connection's database and cache" do
    with_instance_file do |path, uri|
      before = native_owners
      NativeLifetime.fail_connect_after(0)
      expect_raises(DuckDB::Exception, "Connection error") { DB.connect(uri) }
      native_owners.should eq(before)
    ensure
      NativeLifetime.fail_connect_after(-1)
    end
  end

  it "releases earlier connections when initial pool construction fails" do
    with_instance_file do |path, uri|
      before = native_owners
      NativeLifetime.fail_connect_after(2)
      expect_raises(DuckDB::Exception, "Connection error") { DB.open("#{uri}?initial_pool_size=3") }
      native_owners.should eq(before)
    ensure
      NativeLifetime.fail_connect_after(-1)
    end
  end

  it "releases every connection and its owner even when an appender fails to close" do
    before = native_owners
    db = DB.open("#{DuckDB::IN_MEMORY}?initial_pool_size=3&max_idle_pool_size=3")
    cnn = db.checkout.as(DuckDB::Connection)
    cnn.exec "CREATE TABLE required (v INT NOT NULL)"
    cnn.appender("required").row { |row| row << nil }
    expect_raises(DuckDB::Exception, /Failed to close/) { db.close }
    native_owners.should eq(before)
    db.close
  ensure
    db.try &.close
  end

  it "frees errors from both uncached and cached database opens" do
    before = native_owners
    expect_raises(DuckDB::Exception, /read-only/) { DB.connect("duckdb::memory:?access_mode=read_only") }
    native_owners.should eq(before)
    with_instance_file do |path, uri|
      expect_raises(DuckDB::Exception, /IO Error/) { DB.open("#{uri}?access_mode=read_only") }
      native_owners.should eq(before)
    end
  end

  it "keeps literal plus signs in file paths" do
    path = ".tmp/a+b.db"
    File.delete?(path)
    File.delete?(".tmp/a b.db")
    DB.connect("duckdb:#{path}") { |cnn| cnn.exec "CREATE TABLE plus_sign (v INT)" }
    File.exists?(path).should be_true
    File.exists?(".tmp/a b.db").should be_false
    DB.open("duckdb:#{path}") { |db| db.scalar("SELECT count(*) FROM plus_sign").should eq(0_i64) }
  ensure
    File.delete?(".tmp/a+b.db")
    File.delete?(".tmp/a b.db")
  end

  it "excludes all crystal-db options from native configuration when opening" do
    DB.open "#{DuckDB::IN_MEMORY}?initial_pool_size=0&max_pool_size=2&max_idle_pool_size=0&checkout_timeout=1&retry_attempts=0&retry_delay=0&prepared_statements=false&prepared_statements_cache=false" do |db|
      db.prepared_statements?.should be_false
      db.prepared_statements_cache?.should be_false
      db.scalar("SELECT 42").should eq(42)
    end
  end
end
