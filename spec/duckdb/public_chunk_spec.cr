require "../spec_helper"
require "../support/lifecycle"

native_lifetime do
  private def public_handles
    {NativeLifetime.values, NativeLifetime.logical_types, NativeLifetime.chunks, NativeLifetime.results, NativeLifetime.statements, NativeLifetime.appenders}
  end
end

macro chunk_scalar(accessor, sql, expected)
  it "reads {{accessor.id}}, checks NULL, type and bounds" do
    with_cnn do |cnn|
      cnn.each_chunk("SELECT CASE WHEN i=0 THEN {{sql.id}} ELSE NULL END AS v FROM range(2) t(i)") do |chunk|
        chunk.size.should eq(2)
        chunk.column_count.should eq(1)
        chunk.column_name(0).should eq("v")
        vector = chunk.column(0)
        vector.null?(0).should be_false
        vector.{{accessor.id}}(0).should eq({{expected}})
        vector.value(0).should eq({{expected}})
        vector.null?(1).should be_true
        vector.value(1).should be_nil
        expect_raises(DuckDB::Exception, /NULL/) { vector.{{accessor.id}}(1) }
        expect_raises(DuckDB::Exception, /outside/) { vector.{{accessor.id}}(-1) }
        expect_raises(DuckDB::Exception, /outside/) { vector.{{accessor.id}}(2) }
        expect_raises(DuckDB::Exception, /Cannot read/) { vector.struct_child(0) }
      end
    end
  end
end

describe "DuckDB public scalar vectors" do
  chunk_scalar bytes, "'POINT (1 2)'::GEOMETRY", Bytes[1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 240, 63, 0, 0, 0, 0, 0, 0, 0, 64]
  chunk_scalar timestamp, "'1970-01-01 00:00:01'::TIMESTAMP_S", DuckDB::Timestamp.new(1_000_000_i64)
  chunk_scalar timestamp, "'1970-01-01 00:00:00.001'::TIMESTAMP_MS", DuckDB::Timestamp.new(1000_i64)
  chunk_scalar timestamp, "'1970-01-01 00:00:00.000001+00'::TIMESTAMPTZ", DuckDB::Timestamp.from_raw(1_i64, DuckDB::Type::TIMESTAMP_TZ)

  chunk_scalar bool, "true", true
  chunk_scalar int8, "'-128'::TINYINT", Int8::MIN
  chunk_scalar int16, "'-32768'::SMALLINT", Int16::MIN
  chunk_scalar int32, "'-2147483648'::INTEGER", Int32::MIN
  chunk_scalar int64, "'-9223372036854775808'::BIGINT", Int64::MIN
  chunk_scalar int128, "'-170141183460469231731687303715884105728'::HUGEINT", Int128::MIN
  chunk_scalar uint8, "255::UTINYINT", UInt8::MAX
  chunk_scalar uint16, "65535::USMALLINT", UInt16::MAX
  chunk_scalar uint32, "4294967295::UINTEGER", UInt32::MAX
  chunk_scalar uint64, "18446744073709551615::UBIGINT", UInt64::MAX
  chunk_scalar uint128, "'340282366920938463463374607431768211455'::UHUGEINT", UInt128::MAX
  chunk_scalar float32, "1.5::FLOAT", 1.5_f32
  chunk_scalar float64, "1.5::DOUBLE", 1.5_f64
  chunk_scalar string, "'abc' || chr(0) || repeat('x',20)", "abc\0" + "x" * 20
  chunk_scalar string, "'blue'::ENUM('red','blue')", "blue"
  chunk_scalar string, "'101'::BIT", "101"
  chunk_scalar bytes, "encode('a' || chr(0) || 'b')", Bytes[97, 0, 98]
  chunk_scalar decimal, "'-12.30'::DECIMAL(4,2)", DuckDB::Decimal.new(-1230_i128, 4, 2)
  chunk_scalar uuid, "'80000000-0000-0000-0000-000000000001'::UUID", UUID.new("80000000-0000-0000-0000-000000000001")
  chunk_scalar date, "DATE 'infinity'", DuckDB::Date.new("infinity")
  chunk_scalar time_of_day, "TIME '24:00:00'", DuckDB::TimeOfDay.new(24, 0)
  chunk_scalar time_of_day, "'12:34:56.123456789'::TIME_NS", DuckDB::TimeOfDay.new("12:34:56.123456789")
  chunk_scalar time_tz, "TIMETZ '12:00:00+05:30'", DuckDB::TimeTZ.new(DuckDB::TimeOfDay.new(12, 0), 19800)
  chunk_scalar timestamp, "TIMESTAMP 'infinity'", DuckDB::Timestamp.new("infinity")
  chunk_scalar timestamp, "'1969-12-31 23:59:59.999999999'::TIMESTAMP_NS", DuckDB::Timestamp.from_nanoseconds(-1_i128)
  chunk_scalar interval, "INTERVAL '2 months 3 days 4 microseconds'", DuckDB::Interval.new(4_i64, 3, 2)
  chunk_scalar big_num, "42::BIGNUM", DuckDB::BigNum.new(Bytes[0x80, 0, 1, 42])

  it "reads TIMESTAMPTZ_NS through typed and generic access on 2.0" do
    with_cnn do |cnn|
      if cnn.scalar("SELECT version()").as(String).starts_with?("v2.")
        cnn.each_chunk("SELECT '1969-12-31 23:59:59.999999999+00'::TIMESTAMPTZ_NS") do |chunk|
          chunk.column_type(0).should eq(DuckDB::Type::TIMESTAMP_TZ_NS)
          chunk[0].timestamp(0).nanoseconds.should eq(-1)
          chunk[0].timestamp(0).timezone?.should be_true
          chunk[0].value(0).should eq(chunk[0].timestamp(0))
        end
      end
    end
  end

  it "checks cached type ids for every scalar accessor" do
    with_cnn do |cnn|
      cnn.each_chunk("SELECT [1] AS v") do |chunk|
        chunk.column_type(0).should eq(DuckDB::Type::LIST)
        vector = chunk[0]
        {% for accessor in %w(bool int8 int16 int32 int64 int128 uint8 uint16 uint32 uint64 uint128 float32 float64 string bytes decimal uuid date time_of_day time_tz timestamp interval big_num) %}
          expect_raises(DuckDB::Exception, /Cannot read/) { vector.{{accessor.id}}(0) }
        {% end %}
        expect_raises(DuckDB::Exception) { vector.with_bytes(0) { |_| } }
        expect_raises(DuckDB::Exception) { vector.with_string_bytes(0) { |_| } }
        expect_raises(DuckDB::Exception) { vector.array_child }
        [-1, 1].each do |index|
          expect_raises(DuckDB::Exception) { chunk[index] }
          expect_raises(DuckDB::Exception) { chunk.column_type(index) }
          expect_raises(DuckDB::Exception) { chunk.column_name(index) }
        end
      end
    end
  end

  it "copies strings and bytes and yields zero-copy inline, long, empty and NUL data" do
    with_cnn do |cnn|
      saved = [] of String
      blobs = [] of Bytes
      ["", "a\0b", "ü" * 100].each do |text|
        cnn.each_chunk("SELECT ?::VARCHAR, ?::BLOB", text, text.to_slice) do |chunk|
          saved << chunk[0].string(0)
          blobs << chunk[1].bytes(0)
          chunk[0].with_string_bytes(0) { |bytes| bytes.should eq(text.to_slice) }
          chunk[1].with_bytes(0) { |bytes| bytes.should eq(text.to_slice) }
        end
      end
      saved.should eq(["", "a\0b", "ü" * 100])
      blobs.should eq(saved.map(&.to_slice))
      cnn.each_chunk("SELECT NULL::VARCHAR, NULL::BLOB, NULL") do |chunk|
        expect_raises(DuckDB::Exception, /NULL/) { chunk[0].with_string_bytes(0) { |_| } }
        expect_raises(DuckDB::Exception, /NULL/) { chunk[1].with_bytes(0) { |_| } }
        chunk[2].null?(0).should be_true
        chunk[2].value(0).should be_nil
      end
    end
  end
end

describe "DuckDB public nested vectors" do
  it "walks LIST/STRUCT/MAP/ARRAY with NULL containers, children and leaves" do
    with_cnn do |cnn|
      cnn.each_chunk("SELECT [{'a':[1,NULL]},NULL,{'a':NULL}], NULL::INTEGER[], []::INTEGER[], map(['x','y'], [[NULL,3],NULL]), [1,NULL,3]::INTEGER[3], NULL::INTEGER[3]") do |chunk|
        list = chunk[0]
        list.list_size(0).should eq(3)
        rows = [] of Int64
        list.each_list_value(0) do |child, row|
          rows << row
          if row == 1
            child.null?(row).should be_true
          else
            nested = child.struct_child("a")
            child.struct_child(0).value(row).should eq(nested.value(row))
            if row == 2
              nested.null?(row).should be_true
              expect_raises(DuckDB::Exception, /NULL/) { nested.list_size(row) }
            else
              values = [] of DuckDB::Value
              nested.each_list_value(row) { |leaf, index| values << leaf.value(index) }
              values.should eq([1, nil])
            end
          end
          expect_raises(DuckDB::Exception) { child.struct_child("missing") }
          expect_raises(DuckDB::Exception) { child.struct_child(-1) }
        end
        rows.should eq([0, 1, 2])
        chunk[1].null?(0).should be_true
        expect_raises(DuckDB::Exception, /NULL/) { chunk[1].each_list_value(0) { |_, _| } }
        chunk[2].list_size(0).should eq(0)
        chunk[2].each_list_value(0) { |_, _| fail "empty list yielded" }
        pairs = {} of String => DuckDB::Value
        chunk[3].each_list_value(0) { |entry, row| pairs[entry.struct_child("key").string(row)] = entry.struct_child("value").value(row) }
        pairs.should eq({"x" => [nil, 3], "y" => nil})
        chunk[4].list_size(0).should eq(3)
        chunk[4].array_child.int32(0).should eq(1)
        chunk[4].array_child.null?(1).should be_true
        chunk[4].each_list_value(0) { |child, row| child.value(row).should eq([1, nil, 3][row]) }
        chunk[5].null?(0).should be_true
        expect_raises(DuckDB::Exception) { chunk[5].list_size(0) }
        chunk[0].value(0).should eq([{"a" => [1, nil]}, nil, {"a" => nil}])
      end
      cnn.each_chunk("SELECT NULL::STRUCT(a INTEGER), NULL::MAP(VARCHAR,INTEGER), union_value(a:=NULL::INTEGER), union_value(b:='text'), map([]::VARCHAR[], []::INTEGER[])") do |chunk|
        3.times { |i| chunk[i].value(0).should be_nil }
        chunk[3].value(0).should eq("text")
        chunk[4].list_size(0).should eq(0)
      end
    end
  end

  it "uses correct child row indices across chunks and fixed array strides" do
    with_cnn do |cnn|
      count = 0_i64
      cnn.each_chunk("SELECT [i,NULL]::BIGINT[2], [[i,NULL],NULL] FROM range(5000) t(i)") do |chunk|
        chunk.size.times do |row|
          chunk[0].array_child.int64(row * 2).should eq(count)
          chunk[0].array_child.null?(row * 2 + 1).should be_true
          chunk[1].value(row).should eq([[count, nil], nil])
          count += 1
        end
      end
      count.should eq(5000)
    end
  end
end

describe "DuckDB chunk iteration lifetime and execution" do
  it "invalidates every view after each block, including nested children" do
    with_cnn do |cnn|
      saved_chunk : DuckDB::DataChunk? = nil
      saved_vector : DuckDB::Vector? = nil
      saved_child : DuckDB::Vector? = nil
      cnn.each_chunk("SELECT [i] FROM range(5000) t(i)") do |chunk|
        if old = saved_chunk
          expect_raises(DuckDB::Exception, /iteration has ended/) { old.size }
          expect_raises(DuckDB::Exception) { saved_vector.not_nil!.value(0) }
          expect_raises(DuckDB::Exception) { saved_child.not_nil!.int64(0) }
        end
        saved_chunk = chunk
        saved_vector = chunk[0]
        chunk[0].each_list_value(0) { |child, _| saved_child = child }
      end
      old = saved_chunk.not_nil!
      expect_raises(DuckDB::Exception) { old.size }
      expect_raises(DuckDB::Exception) { old.column_count }
      expect_raises(DuckDB::Exception) { old.column_name(0) }
      expect_raises(DuckDB::Exception) { old.column_type(0) }
      expect_raises(DuckDB::Exception) { old[0] }
      vector = saved_vector.not_nil!
      {% for accessor in %w(null? bool int8 int16 int32 int64 int128 uint8 uint16 uint32 uint64 uint128 float32 float64 string bytes decimal uuid date time_of_day time_tz timestamp interval big_num value list_size) %}
        expect_raises(DuckDB::Exception, /iteration has ended/) { vector.{{accessor.id}}(0) }
      {% end %}
      expect_raises(DuckDB::Exception) { vector.each_list_value(0) { |_, _| } }
      expect_raises(DuckDB::Exception) { vector.struct_child(0) }
      expect_raises(DuckDB::Exception) { vector.struct_child("a") }
      expect_raises(DuckDB::Exception) { vector.array_child }
      expect_raises(DuckDB::Exception) { vector.with_bytes(0) { |_| } }
      expect_raises(DuckDB::Exception) { vector.with_string_bytes(0) { |_| } }
    end
  end

  it "overrides stream_results at the call and retains the streaming guard" do
    DB.connect "duckdb::memory:?stream_results=true" do |db|
      cnn = db.as(DuckDB::Connection)
      before = native_lifetime { NativeLifetime.streaming_executions }
      cnn.each_chunk("SELECT ?::BIGINT", 42) do |chunk|
        chunk[0].int64(0).should eq(42)
        cnn.each_chunk("SELECT 1") { |c| c[0].int32(0).should eq(1) }
      end
      native_lifetime { NativeLifetime.streaming_executions.should eq(before) }
      cnn.stream_results.should be_true
      cnn.stream_results = false
      rows = 0_i64
      cnn.each_chunk("SELECT i FROM range(5000) t(i)", stream: true) do |chunk|
        expect_raises(DuckDB::Exception, /active streaming result/) { cnn.scalar("SELECT 7") }
        expect_raises(DuckDB::Exception, /active streaming result/) { cnn.each_chunk("SELECT 7") { |_| } }
        chunk.size.times { |r| chunk[0].int64(r).should eq(rows); rows += 1 }
      end
      rows.should eq(5000)
      native_lifetime { NativeLifetime.streaming_executions.should eq(before + 1) }
      cnn.stream_results.should be_false
      cnn.scalar("SELECT 7").should eq(7)
    end
  end

  it "releases all handles after normal, break, exception, binding and SQL failures" do
    with_cnn do |cnn|
      before = native_lifetime { public_handles }
      cnn.each_chunk("SELECT i FROM range(5000) t(i)") { |_| break }
      expect_raises(Exception, /user failure/) { cnn.each_chunk("SELECT 1", stream: true) { |_| raise "user failure" } }
      expect_raises(DuckDB::Exception, /Expected 2 arguments, got 1/) { cnn.each_chunk("SELECT ? + ?", 1) { |_| } }
      expect_raises(DuckDB::Exception) { cnn.each_chunk("SELECT ?", 1, 2) { |_| } }
      expect_raises(DuckDB::Exception) { cnn.each_chunk("SELECT ?::INTEGER", "bad") { |_| } }
      expect_raises(DuckDB::Exception, /NUL/) { cnn.each_chunk("SELECT 1\0 +2") { |_| } }
      expect_raises(DuckDB::Exception) { cnn.each_chunk("SELECT FROM") { |_| } }
      cnn.each_chunk("SELECT 1 WHERE false") { |_| fail "empty result yielded" }
      native_lifetime { public_handles.should eq(before) }
    end
  end

  it "invalidates a chunk when the connection closes inside the block" do
    cnn = DB.connect("duckdb::memory:").as(DuckDB::Connection)
    expect_raises(DuckDB::Exception) do
      cnn.each_chunk("SELECT 1") do |chunk|
        vector = chunk[0]
        cnn.close
        expect_raises(DuckDB::Exception) { chunk.size }
        vector.int32(0)
      end
    end
  ensure
    cnn.try &.close
  end

  it "pins zero-copy buffers until callback exit even if the connection closes" do
    before = native_lifetime { public_handles }
    cnn = DB.connect("duckdb::memory:").as(DuckDB::Connection)
    expect_raises(DuckDB::Exception, /closed/) do
      cnn.each_chunk("SELECT encode(repeat('x',100)), repeat('y',100)") do |chunk|
        blob, text = chunk[0], chunk[1]
        blob.with_bytes(0) do |bytes|
          text.with_string_bytes(0) do |string_bytes|
            cnn.close
            expect_raises(DuckDB::Exception, /iteration has ended/) { blob.bytes(0) }
            expect_raises(DuckDB::Exception) { chunk.size }
            native_lifetime { NativeLifetime.chunks.should eq(before[2] + 1) }
            bytes.should eq(("x" * 100).to_slice)
            string_bytes.should eq(("y" * 100).to_slice)
          end
          bytes.should eq(("x" * 100).to_slice)
          native_lifetime { NativeLifetime.chunks.should eq(before[2] + 1) }
        end
        native_lifetime { NativeLifetime.chunks.should eq(before[2]) }
      end
    end
    native_lifetime { public_handles.should eq(before) }
  ensure
    cnn.try &.close
  end

  it "surfaces errors after some streaming chunks and returns handles to baseline" do
    DB.connect "duckdb::memory:?threads=1&prepared_statements_cache=false" do |db|
      cnn = db.as(DuckDB::Connection)
      before = native_lifetime { public_handles }
      rows = 0_i64
      expect_raises(DuckDB::Exception, /boom/) do
        cnn.each_chunk("SELECT CASE WHEN i = 5000000 THEN error('boom') ELSE i END FROM range(10000000) t(i)", stream: true) { |chunk| rows += chunk.size }
      end
      rows.should be > 0
      native_lifetime { public_handles.should eq(before) }
      cnn.scalar("SELECT 42").should eq(42)
    end
  end

  it "holds a pooled connection until the whole block exits, including failures" do
    DB.open "duckdb::memory:?max_pool_size=1&checkout_timeout=0.01" do |db|
      pool = db.as(DuckDB::PooledDatabase)
      [false, true].each do |stream|
        pool.each_chunk("SELECT ?::BIGINT", 42, stream: stream) do |chunk|
          db.pool.stats.idle_connections.should eq(0)
          chunk[0].int64(0).should eq(42)
        end
        db.pool.stats.idle_connections.should eq(1)
        pool.each_chunk("SELECT 1", stream: stream) { |_| break }
        db.pool.stats.idle_connections.should eq(1)
        expect_raises(Exception) { pool.each_chunk("SELECT 1", stream: stream) { |_| raise "pool failure" } }
        db.pool.stats.idle_connections.should eq(1)
      end
      pool.scalar("SELECT 1").should eq(1)
    end
  end
end
