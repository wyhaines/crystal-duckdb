require "../spec_helper"
require "../support/lifecycle"
require "log/spec"

native_lifetime do
  private def nested_pool_handles
    {NativeLifetime.values, NativeLifetime.logical_types, NativeLifetime.appenders,
     NativeLifetime.results, NativeLifetime.statements, NativeLifetime.chunks,
     NativeLifetime.connections, NativeLifetime.databases}
  end
end

describe "DuckDB pooled nested parameters" do
  it "supports query, exec, args enumerables and chunks with cached statements" do
    before = native_lifetime { nested_pool_handles }
    DB.open "duckdb::memory:?max_pool_size=1" do |db|
      db.exec "CREATE TABLE pooled_nested (a INTEGER[], s STRUCT(x INTEGER[2]))"
      values = [1, nil, 2] of DuckDB::Value
      fields = {"x" => ([1, nil] of DuckDB::Value)} of String => DuckDB::Value
      db.exec "INSERT INTO pooled_nested VALUES (?, ?)", values, fields
      db.exec "INSERT INTO pooled_nested VALUES (?, ?)", args: [values, fields] of DuckDB::Value
      db.query("SELECT a,s FROM pooled_nested") do |rs|
        2.times do
          rs.move_next.should be_true
          rs.read.should eq(values)
          rs.read.should eq(fields)
        end
      end
      db.as(DuckDB::PooledDatabase).each_chunk("SELECT ?::INTEGER[]", values) { |c| c[0].value(0).should eq(values) }
      db.pool.stats.idle_connections.should eq(1)
      expect_raises(DuckDB::Exception) { db.exec "INSERT INTO pooled_nested VALUES (?, ?)", values, {wrong: [1, 2]} }
      db.pool.stats.idle_connections.should eq(1)
      db.scalar("SELECT ? = ANY([[1,2],[3,4]])", [1, 2]).should be_true
      # An unresolved cached parameter must accept a different inferred type.
      db.scalar("SELECT ?", [1]).should eq([1])
      db.scalar("SELECT ?", ["text"]).should eq(["text"])
      db.scalar("SELECT ?", {"x" => 1}).should eq({"x" => 1})
    end
    native_lifetime { nested_pool_handles.should eq(before) }
  end

  it "logs recursive containers and rejects unprepared arguments without compiler errors" do
    DB.connect "duckdb::memory:?prepared_statements_cache=false" do |cnn|
      values = cnn.scalar("SELECT [NULL, {'a':[1,NULL]}]").as(Array(DuckDB::Value))
      Log.capture(DB::Log.source) do |logs|
        cnn.scalar("SELECT ?::STRUCT(a INTEGER[])[]", values).should eq(values)
        logs.check(:debug, /Executing query/)
      end
      expect_raises(DuckDB::Exception, /Unprepared.*args/) { cnn.unprepared.exec("SELECT ?", values) }
    end
  end

  {% if compare_versions(Crystal::VERSION, "1.21.0") >= 0 %}
    it "binds and appends recursively through a four-thread pool" do
      before = native_lifetime { nested_pool_handles }
      DB.open "duckdb::memory:?threads=1&initial_pool_size=0&max_pool_size=4&max_idle_pool_size=4" do |db|
        12.times { |i| db.exec "CREATE TABLE nested_worker_#{i} (v STRUCT(a INTEGER[2], b MAP(VARCHAR, INTEGER[])))" }
        context = Fiber::ExecutionContext::Parallel.new("duckdb-nested-spec", 4)
        done = Channel(Exception?).new(12)
        modern = db.scalar("SELECT version()").as(String).starts_with?("v2.")
        12.times do |worker|
          context.spawn do
            begin
              4.times do |iteration|
                value = {a: [worker, nil], b: {"x" => [iteration, nil]}}
                db.exec "INSERT INTO nested_worker_#{worker} VALUES (?)", value
                db.query("SELECT ?::INTEGER[]", [worker, nil]) do |rs|
                  Fiber.yield
                  rs.move_next.should be_true
                  rs.read.should eq([worker, nil])
                end
                db.using_connection do |cnn|
                  cnn.as(DuckDB::Connection).appender("nested_worker_#{worker}") do |a|
                    a.row { |r| r << value; Fiber.yield }
                  end
                end
                tz = DuckDB::Timestamp.from_nanoseconds(-1_i128, timezone: true)
                if modern
                  db.scalar("SELECT ?::TIMESTAMPTZ_NS[]", [tz]).should eq([tz])
                else
                  expect_raises(DuckDB::Exception, /unavailable/) { db.scalar("SELECT ?", tz) }
                end
              end
              db.scalar("SELECT count(*) FROM nested_worker_#{worker}").should eq(8)
              done.send(nil)
            rescue ex
              done.send(ex)
            end
          end
        end
        errors = [] of Exception
        12.times do
          select
          when error = done.receive
            errors << error if error
          when timeout(30.seconds)
            abort "nested pool workers timed out"
          end
        end
        raise errors[0] unless errors.empty?
      end
      native_lifetime { nested_pool_handles.should eq(before) }
      native_lifetime { NativeLifetime.tz_ns_lookups.should eq(1) }
    end
  {% end %}
end
