require "../spec_helper"
require "../support/lifecycle"

# Execution contexts were released in 1.21. Keep this file compilable on the
# shard's minimum Crystal, including when VERSION has a development suffix.
{% if compare_versions(Crystal::VERSION, "1.21.0") >= 0 %}
  module ExecutionContextSpec
    class ReleaseCounter
      include DB::ConnectionContext
      getter count = Atomic(Int32).new(0)
      property statement : DB::Statement?
      getter released_while_open = Atomic(Bool).new(false)

      def discard(connection : DB::Connection)
      end

      def release(connection : DB::Connection)
        @count.add(1)
        if statement = @statement
          @released_while_open.set(true) unless statement.closed?
        end
      end
    end

    class PausingDatabase < DuckDB::Database
      def initialize(options : DuckDB::Connection::Options, @checked : Channel(Nil), @continue : Channel(Nil))
        super(options)
      end

      def closed? : Bool
        value = super
        @checked.send(nil)
        @continue.receive
        value
      end
    end

    class Builder < DuckDB::Driver::ConnectionBuilder
      def owner=(@database : DuckDB::Database)
      end
    end

    # Enlarge the real publication window between building a resource and the
    # checkout caller reacquiring the mutex. No connection use is mocked.
    class YieldingPool < DuckDB::Pool
      private def build_resource : DB::Connection
        super.tap { Fiber.yield }
      end
    end

    def self.handles
      {NativeLifetime.databases, NativeLifetime.connections, NativeLifetime.caches,
       NativeLifetime.open_errors, NativeLifetime.results, NativeLifetime.statements,
       NativeLifetime.appenders, NativeLifetime.chunks, NativeLifetime.logical_types,
       NativeLifetime.values, NativeLifetime.extracted_statements}
    end

    def self.receive(channel : Channel(T)) : T forall T
      select
      when value = channel.receive
        value
      when timeout(30.seconds)
        abort "execution context worker timed out after 30 seconds"
      end
    end

    def self.run(count : Int32, &block : Int32 ->)
      context = Fiber::ExecutionContext::Parallel.new("duckdb-spec", 4)
      done = Channel(Exception?).new(count)
      count.times do |index|
        context.spawn do
          begin
            block.call(index)
            done.send(nil)
          rescue ex
            done.send(ex)
          end
        end
      end
      error = nil
      count.times do
        select
        when ex = done.receive
          error ||= ex
        when timeout(30.seconds)
          abort "execution context workers timed out after 30 seconds"
        end
      end
      raise error if error
    end
  end

  describe "DuckDB execution contexts" do
    it "never checks out a growing pool's connection to two fibers" do
      options = DB::Pool::Options.new(initial_pool_size: 0, max_pool_size: 4, max_idle_pool_size: 4)
      pool = ExecutionContextSpec::YieldingPool.new(options) { DB.connect("duckdb::memory:?threads=1") }
      active = Set(UInt64).new
      mutex = Mutex.new
      ExecutionContextSpec.run(32) do |_|
        pool.checkout do |conn|
          id = conn.object_id
          acquired = mutex.synchronize { !!active.add?(id) }
          begin
            acquired.should be_true
            sleep 1.millisecond
          ensure
            mutex.synchronize { active.delete(id) } if acquired
          end
        end
      end
    ensure
      pool.try &.close
    end

    it "serializes stats, availability, discard and close with pool operations" do
      [:stats, :available, :delete, :close].each do |operation|
        connection = DB.connect("duckdb::memory:?threads=1")
        pool = DuckDB::Pool.new(DB::Pool::Options.new) { connection }
        context = Fiber::ExecutionContext::Parallel.new("duckdb-pool-lock", 4)
        locked = Channel(Nil).new(1)
        unlock = Channel(Nil).new(1)
        holder_done = Channel(Nil).new(1)
        attempted = Channel(Nil).new(1)
        done = Channel(Exception?).new(1)
        context.spawn do
          pool.each_resource do |_|
            locked.send(nil)
            unlock.receive
          end
          holder_done.send(nil)
        end
        ExecutionContextSpec.receive(locked)
        context.spawn do
          attempted.send(nil)
          begin
            case operation
            when :stats     then pool.stats
            when :available then pool.is_available?(connection)
            when :delete    then pool.delete(connection)
            when :close     then pool.close
            end
            done.send(nil)
          rescue ex
            done.send(ex)
          end
        end
        ExecutionContextSpec.receive(attempted)
        begin
          select
          when error = done.receive
            raise error if error
            fail "#{operation} accessed the pool while another fiber held its mutex"
          when timeout(10.milliseconds)
          end
        ensure
          unlock.send(nil)
        end
        ExecutionContextSpec.receive(holder_done)
        error = ExecutionContextSpec.receive(done)
        raise error if error
        pool.close
        connection.close
      end
    end

    it "runs prepared queries, execs and chunks through one contended pool" do
      before = ExecutionContextSpec.handles
      DB.open "duckdb::memory:?threads=1&initial_pool_size=0&max_pool_size=4&max_idle_pool_size=4" do |db|
        db.exec "CREATE TABLE writes (v BIGINT)"
        prepared = db.prepared("SELECT ?::BIGINT * 7")
        ExecutionContextSpec.run(32) do |worker|
          4.times do |iteration|
            value = (worker * 4 + iteration).to_i64
            prepared.scalar(value).should eq(value * 7)
            db.exec("INSERT INTO writes VALUES (?)", value).rows_affected.should eq(1)
            db.query("SELECT ?::BIGINT, ?::VARCHAR", value, "worker-#{worker}") do |rs|
              Fiber.yield
              rs.move_next.should be_true
              rs.read(Int64).should eq(value)
              rs.read(String).should eq("worker-#{worker}")
              rs.move_next.should be_false
            end
            rows = 0_i64
            db.as(DuckDB::PooledDatabase).each_chunk("SELECT i + ?::BIGINT FROM range(5000) t(i)", value, stream: iteration.odd?) do |chunk|
              Fiber.yield
              chunk.size.times do |row|
                chunk[0].int64(row).should eq(rows + value)
                rows += 1
              end
            end
            rows.should eq(5000)
          end
        end
        db.scalar("SELECT count(*) FROM writes").should eq(128)
        db.scalar("SELECT sum(v)::BIGINT FROM writes").should eq(8128)
        db.pool.stats.idle_connections.should eq(4)
      end
      ExecutionContextSpec.handles.should eq(before)
    end

    it "reuses per-connection statement caches and releases failed and discarded checkouts" do
      before = ExecutionContextSpec.handles
      DB.open "duckdb::memory:?threads=1&initial_pool_size=0&max_pool_size=4&max_idle_pool_size=2" do |db|
        ExecutionContextSpec.run(32) do |worker|
          8.times do |iteration|
            db.using_connection do |conn|
              sql = "SELECT ?::BIGINT + 1"
              statement = conn.prepared(sql)
              conn.prepared(sql).should be(statement)
              Fiber.yield
              statement.scalar(worker.to_i64).should eq(worker + 1)
              expect_raises(DuckDB::Exception) { conn.scalar("SELECT ?::BIGINT", "bad") }
              conn.unprepared.scalar("SELECT 42::BIGINT").should eq(42)
              # Closing an exclusively held checkout calls discard while other
              # fibers grow and release the pool, including release-triggered close.
              conn.close if iteration.even?
              db.pool.stats.open_connections.should be <= 4
            end
          end
        end
        db.scalar("SELECT 99::BIGINT").should eq(99)
      end
      ExecutionContextSpec.handles.should eq(before)
    end

    it "releases a failed unprepared stream exactly once" do
      before = ExecutionContextSpec.handles
      DB.connect "duckdb::memory:?threads=1&stream_results=true" do |conn|
        counter = ExecutionContextSpec::ReleaseCounter.new
        conn.context = counter
        expect_raises(DuckDB::Exception, /Conversion Error/) do
          conn.unprepared.query("SELECT CAST('bad' AS BIGINT)") do |rs|
            rs.each { rs.read(Int64) }
          end
        end
        counter.count.get.should eq(1)
      end
      ExecutionContextSpec.handles.should eq(before)
    end

    it "discards a closing connection without returning its active result's lease" do
      before = ExecutionContextSpec.handles
      conn = DB.connect("duckdb::memory:?threads=1")
      counter = ExecutionContextSpec::ReleaseCounter.new
      conn.context = counter
      rs = conn.query("SELECT 42::BIGINT")
      conn.close
      rs.closed?.should be_true
      counter.count.get.should eq(0)
      ExecutionContextSpec.handles.should eq(before)
    ensure
      conn.try &.close
    end

    it "releases an explicitly closed statement's lease only after native cleanup" do
      before = ExecutionContextSpec.handles
      DB.connect "duckdb::memory:?threads=1" do |conn|
        counter = ExecutionContextSpec::ReleaseCounter.new
        conn.context = counter
        statement = conn.build_prepared_statement("SELECT 42::BIGINT")
        counter.statement = statement
        rs = statement.query
        statement.close
        rs.closed?.should be_true
        statement.closed?.should be_true
        counter.count.get.should eq(1)
        counter.released_while_open.get.should be_false
      end
      ExecutionContextSpec.handles.should eq(before)
    end

    it "returns failed unprepared streams safely under pool contention" do
      before = ExecutionContextSpec.handles
      DB.open "duckdb::memory:?threads=1&stream_results=true&max_pool_size=4&max_idle_pool_size=4" do |db|
        ExecutionContextSpec.run(32) do |worker|
          4.times do
            expect_raises(DuckDB::Exception, /Conversion Error/) do
              db.unprepared.query("SELECT CAST('bad' AS BIGINT)") do |rs|
                rs.each { rs.read(Int64) }
              end
            end
            db.query("SELECT ?::BIGINT FROM range(100)", worker.to_i64) do |rs|
              Fiber.yield
              rows = 0
              rs.each do
                rs.read(Int64).should eq(worker)
                rows += 1
              end
              rows.should eq(100)
            end
          end
        end
      end
      ExecutionContextSpec.handles.should eq(before)
    end

    it "streams on separate connections while fibers yield between rows" do
      before = ExecutionContextSpec.handles
      DB.open "duckdb::memory:?threads=1&stream_results=true&max_pool_size=4&max_idle_pool_size=4" do |db|
        ExecutionContextSpec.run(24) do |worker|
          db.using_connection do |conn|
            2.times do
              row = 0_i64
              conn.query("SELECT i + ?::BIGINT FROM range(10000) t(i)", worker.to_i64) do |rs|
                rs.each do
                  rs.read(Int64).should eq(row + worker)
                  row += 1
                  Fiber.yield if row % 257 == 0
                end
              end
              row.should eq(10000)
            end
          end
        end
      end
      ExecutionContextSpec.handles.should eq(before)
    end

    it "keeps a pool lease until its last appender closes" do
      before = ExecutionContextSpec.handles
      DB.open "duckdb::memory:?threads=1&max_pool_size=1&max_idle_pool_size=1" do |db|
        rs = db.query("SELECT 42::BIGINT")
        connection = rs.statement.connection.as(DuckDB::Connection)
        connection.exec "CREATE TABLE appended (v BIGINT)"
        appender = connection.appender("appended")
        begin
          rs.close
          db.pool.stats.idle_connections.should eq(0)
          appender.row { |row| row << 42_i64 }
          appender.close
          db.pool.stats.idle_connections.should eq(1)
          db.scalar("SELECT v FROM appended").should eq(42)
        ensure
          appender.close
          rs.close
        end
      end
      ExecutionContextSpec.handles.should eq(before)
    end

    it "appends to separate tables on separate connections across yields" do
      before = ExecutionContextSpec.handles
      DB.open "duckdb::memory:?threads=1&max_pool_size=4&max_idle_pool_size=4" do |db|
        24.times { |i| db.exec "CREATE TABLE append_#{i} (v BIGINT, label VARCHAR)" }
        ExecutionContextSpec.run(24) do |worker|
          db.using_connection do |conn|
            conn.as(DuckDB::Connection).appender("append_#{worker}") do |appender|
              300.times do |row|
                appender.row do |r|
                  r << row.to_i64
                  Fiber.yield if row % 17 == 0
                  r << "worker-#{worker}"
                end
              end
            end
            conn.scalar("SELECT count(*) FROM append_#{worker} WHERE label = ?", "worker-#{worker}").should eq(300)
            conn.scalar("SELECT sum(v)::BIGINT FROM append_#{worker}").should eq(44850)
          end
        end
      end
      ExecutionContextSpec.handles.should eq(before)
    end

    it "opens and closes owners on the same file and named memory database without losing writes" do
      before = ExecutionContextSpec.handles
      path = ".tmp/execution-context-#{Random.rand(1_u64..UInt64::MAX)}.db"
      ["duckdb:#{path}", "duckdb::memory:execution-context-#{Random.rand(1_u64..UInt64::MAX)}"].each do |uri|
        # Keep the named database alive while independent owners come and go.
        DB.connect "#{uri}?threads=1" do |anchor|
          anchor.exec "CREATE TABLE writes (v BIGINT)"
          ExecutionContextSpec.run(24) do |worker|
            4.times do |iteration|
              value = (worker * 4 + iteration).to_i64
              DB.open "#{uri}?threads=1&initial_pool_size=0&max_pool_size=2&max_idle_pool_size=0" do |db|
                db.exec "INSERT INTO writes VALUES (?)", value * 2
                Fiber.yield
                db.scalar("SELECT count(*) FROM writes").as(Int64).should be > 0
              end
              DB.connect "#{uri}?threads=1" do |conn|
                conn.exec "INSERT INTO writes VALUES (?)", value * 2 + 1
                Fiber.yield
                conn.scalar("SELECT ?::BIGINT", value).should eq(value)
              end
            end
          end
          anchor.scalar("SELECT count(*) FROM writes").should eq(192)
          anchor.scalar("SELECT count(DISTINCT v) FROM writes").should eq(192)
          anchor.scalar("SELECT sum(v)::BIGINT FROM writes").should eq(18336)
        end
        ExecutionContextSpec.handles.should eq(before)
      end
    ensure
      if path
        File.delete?(path)
        File.delete?("#{path}.wal")
      end
    end

    it "contends on one connection builder and its database owner" do
      before = ExecutionContextSpec.handles
      uri = "duckdb::memory:execution-builder-#{Random.rand(1_u64..UInt64::MAX)}?threads=1"
      builder = DuckDB::Driver.new.connection_builder(URI.parse(uri)).as(DuckDB::Driver::ConnectionBuilder)
      4.times do
        ExecutionContextSpec.run(32) do |worker|
          conn = builder.build
          begin
            Fiber.yield
            conn.scalar("SELECT ?::BIGINT", worker.to_i64).should eq(worker)
          ensure
            conn.close
          end
        end
        ExecutionContextSpec.handles.should eq(before)
      end
      builder.close
      ExecutionContextSpec.handles.should eq(before)
    end

    it "reopens an owner whose last connection closes during a builder checkout" do
      before = ExecutionContextSpec.handles
      checked = Channel(Nil).new(1)
      continue = Channel(Nil).new(1)
      options = DuckDB::Connection::Options.from_uri(URI.parse("duckdb::memory:?threads=1"))
      database = ExecutionContextSpec::PausingDatabase.new(options, checked, continue)
      first = DuckDB::Connection.new(DB::Connection::Options.new, database)
      builder = ExecutionContextSpec::Builder.new(DB::Connection::Options.new, options)
      builder.owner = database
      context = Fiber::ExecutionContext::Parallel.new("duckdb-owner-close", 4)
      done = Channel(Exception?).new(1)
      context.spawn do
        begin
          connection = builder.build
          begin
            connection.scalar("SELECT 42::BIGINT").should eq(42)
          ensure
            connection.close
          end
          done.send(nil)
        rescue ex
          done.send(ex)
        end
      end
      ExecutionContextSpec.receive(checked)
      first.close
      continue.send(nil)
      error = ExecutionContextSpec.receive(done)
      raise error if error
      builder.close
      ExecutionContextSpec.handles.should eq(before)
    ensure
      first.try &.close
      builder.try &.close
    end

    it "serializes setup hooks with in-flight connection initialization" do
      before = ExecutionContextSpec.handles
      DB.open "duckdb::memory:?threads=1&initial_pool_size=0&max_pool_size=2" do |db|
        entered = Channel(Nil).new(1)
        continue = Channel(Nil).new(1)
        query_done = Channel(Exception?).new(1)
        setup_done = Channel(Exception?).new(1)
        attempted = Channel(Nil).new(1)
        db.setup_connection do |_|
          entered.send(nil)
          continue.receive
        end
        context = Fiber::ExecutionContext::Parallel.new("duckdb-setup", 4)
        context.spawn do
          begin
            db.scalar("SELECT 42::BIGINT").should eq(42)
            query_done.send(nil)
          rescue ex
            query_done.send(ex)
          end
        end
        ExecutionContextSpec.receive(entered)
        context.spawn do
          attempted.send(nil)
          begin
            db.setup_connection { |_| }
            setup_done.send(nil)
          rescue ex
            setup_done.send(ex)
          end
        end
        ExecutionContextSpec.receive(attempted)
        begin
          select
          when error = setup_done.receive
            raise error if error
            fail "setup hook changed during connection initialization"
          when timeout(10.milliseconds)
          end
        ensure
          continue.send(nil)
        end
        error = ExecutionContextSpec.receive(query_done)
        raise error if error
        error = ExecutionContextSpec.receive(setup_done)
        raise error if error
      end
      ExecutionContextSpec.handles.should eq(before)
    end

    it "reserves idle connections while a setup hook runs multiple queries" do
      before = ExecutionContextSpec.handles
      DB.open "duckdb::memory:?threads=1&max_pool_size=1&max_idle_pool_size=1" do |db|
        db.scalar("SELECT 1::BIGINT").should eq(1)
        db.setup_connection do |conn|
          conn.scalar("SELECT 41::BIGINT").should eq(41)
          Fiber.yield
          conn.scalar("SELECT 42::BIGINT").should eq(42)
        end
        db.pool.stats.idle_connections.should eq(1)
        db.scalar("SELECT 43::BIGINT").should eq(43)
      end
      ExecutionContextSpec.handles.should eq(before)
    end

    it "keeps default-context fibers responsive during an isolated analytical query" do
      before = ExecutionContextSpec.handles
      started = Channel(Nil).new(1)
      done = Channel(Exception?).new(1)
      running = Atomic(Bool).new(true)
      ticks = Atomic(Int32).new(0)
      heartbeat_done = Channel(Nil).new(1)
      isolated = Fiber::ExecutionContext::Isolated.new("duckdb-analytical-query") do
        begin
          DB.connect "duckdb::memory:?threads=1" do |conn|
            started.send(nil)
            conn.scalar("SELECT count(*) FROM range(10000) a(i), range(10000) b(i) WHERE (a.i*b.i)%97=0").should eq(2_069_184)
          end
          done.send(nil)
        rescue ex
          done.send(ex)
        ensure
          running.set(false)
        end
      end
      ExecutionContextSpec.receive(started)
      Fiber::ExecutionContext.default.spawn do
        while running.get
          sleep 5.milliseconds
          ticks.add(1) if running.get
        end
        heartbeat_done.send(nil)
      end
      error = ExecutionContextSpec.receive(done)
      ExecutionContextSpec.receive(heartbeat_done)
      isolated.join
      raise error if error
      ticks.get.should be >= 3
      ExecutionContextSpec.handles.should eq(before)
    end
  end
{% else %}
  describe "DuckDB execution contexts" do
    pending "requires Crystal 1.21 or later"
  end
{% end %}
