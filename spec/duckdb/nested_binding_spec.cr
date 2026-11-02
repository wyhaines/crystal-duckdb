require "../spec_helper"
require "../support/lifecycle"

native_lifetime do
  private def nested_handles
    {NativeLifetime.values, NativeLifetime.logical_types, NativeLifetime.appenders,
     NativeLifetime.results, NativeLifetime.statements, NativeLifetime.chunks}
  end
end

private def nested_round_trip(cnn, type, value)
  cnn.exec "CREATE OR REPLACE TABLE nested_round_trip (v #{type})"
  cnn.exec("INSERT INTO nested_round_trip VALUES (?)", value)
  cnn.as(DuckDB::Connection).appender("nested_round_trip") { |a| a.row { |r| r << value } }
  cnn.query("SELECT v FROM nested_round_trip") do |rs|
    2.times do
      rs.move_next.should be_true
      rs.read.should eq(value)
    end
    rs.move_next.should be_false
  end
end

macro nested_leaf(type, value)
  it "binds and appends {{type.id}} leaves, including NULL" do
    DB.connect "duckdb::memory:?prepared_statements_cache=false" do |cnn|
      before = native_lifetime { nested_handles }
      value = {{value}}
      nested_round_trip(cnn, {{type}} + "[]", [value, nil])
      native_lifetime { nested_handles.should eq(before) }
    end
  end
end

describe "DuckDB nested binding and appending" do
  nested_leaf "BOOLEAN", true
  nested_leaf "TINYINT", Int8::MIN
  nested_leaf "SMALLINT", Int16::MAX
  nested_leaf "INTEGER", Int32::MIN
  nested_leaf "BIGINT", Int64::MAX
  nested_leaf "HUGEINT", Int128::MIN
  nested_leaf "UTINYINT", UInt8::MAX
  nested_leaf "USMALLINT", UInt16::MAX
  nested_leaf "UINTEGER", UInt32::MAX
  nested_leaf "UBIGINT", UInt64::MAX
  nested_leaf "UHUGEINT", UInt128::MAX
  nested_leaf "FLOAT", 1.5_f32
  nested_leaf "DOUBLE", 1.5_f64
  nested_leaf "VARCHAR", "a\0ü" * 10
  nested_leaf "BLOB", Bytes[0, 255, 12]
  nested_leaf "BLOB", Bytes.empty
  nested_leaf "UUID", UUID.new("ffffffff-ffff-ffff-ffff-ffffffffffff")
  nested_leaf "DATE", DuckDB::Date.new("infinity")
  nested_leaf "TIME", DuckDB::TimeOfDay.new(24, 0)
  nested_leaf "TIME_NS", DuckDB::TimeOfDay.from_nanoseconds(1_i64)
  nested_leaf "TIMETZ", DuckDB::TimeTZ.new(DuckDB::TimeOfDay.new(12, 0), -19801)
  nested_leaf "TIMESTAMP", DuckDB::Timestamp.new("-infinity")
  nested_leaf "TIMESTAMP_NS", DuckDB::Timestamp.from_nanoseconds(-1_i128)
  nested_leaf "TIMESTAMP_MS", DuckDB::Timestamp.from_raw(Int64::MAX - 1, DuckDB::Type::TIMESTAMP_MS)
  nested_leaf "TIMESTAMP_S", DuckDB::Timestamp.from_raw(-Int64::MAX + 1, DuckDB::Type::TIMESTAMP_S)
  nested_leaf "TIMESTAMPTZ", DuckDB::Timestamp.from_raw(1_i64, DuckDB::Type::TIMESTAMP_TZ)
  nested_leaf "INTERVAL", DuckDB::Interval.new(4_i64, 3, 2)
  nested_leaf "BIGNUM", DuckDB::BigNum.new(Bytes[0x80, 0, 1, 42])
  nested_leaf "BIGNUM", cnn.scalar("SELECT ?::BIGNUM", "-" + "9" * 1000).as(DuckDB::BigNum)
  nested_leaf "BIT", "101001"
  nested_leaf "ENUM('red','blue')", "blue"
  {% for width in [4, 9, 18, 38] %}
    nested_leaf "DECIMAL({{width}},2)", DuckDB::Decimal.new(-(10_i128 ** {{width}} - 1), {{width}}, 2)
  {% end %}

  it "uses destination INTEGER, BIGINT and DECIMAL child types" do
    with_cnn do |cnn|
      %w(INTEGER BIGINT).each do |type|
        cnn.scalar("SELECT ?::#{type}[]", [1, nil, 2]).should eq([1, nil, 2])
        cnn.exec "CREATE OR REPLACE TABLE typed_children (v #{type}[])"
        cnn.appender("typed_children") { |a| a.row { |r| r << [1, nil, 2] } }
        cnn.scalar("SELECT v FROM typed_children").should eq([1, nil, 2])
      end
      cnn.scalar("SELECT ?::DECIMAL(10,2)[]", [1, 2]).should eq([DuckDB::Decimal.new(100_i128, 10, 2), DuckDB::Decimal.new(200_i128, 10, 2)])
      cnn.exec "CREATE TABLE decimal_children (v DECIMAL(10,2)[])"
      cnn.appender("decimal_children") { |a| a.row { |r| r << [1, 2] } }
      cnn.scalar("SELECT v FROM decimal_children").should eq(cnn.scalar("SELECT ?::DECIMAL(10,2)[]", [1, 2]))
    end
  end

  it "maps Array, Slice and StaticArray to LIST or a checked fixed ARRAY" do
    with_cnn do |cnn|
      values = [1, 2, 3]
      [values, Slice[1, 2, 3], StaticArray[1, 2, 3]].each do |value|
        cnn.scalar("SELECT ?", value).should eq(values)
        cnn.scalar("SELECT ?::INTEGER[3]", value).should eq(values)
        cnn.exec "CREATE OR REPLACE TABLE arrays (v INTEGER[3])"
        cnn.appender("arrays") { |a| a.row { |r| r << value } }
        cnn.scalar("SELECT v FROM arrays").should eq(values)
      end
      cnn.scalar("SELECT ?", Bytes[1, 2]).should eq(Bytes[1, 2])
      nested_round_trip(cnn, "INTEGER[3]", [1, nil, 3])
      expect_raises(DuckDB::Exception, /requires 3 elements/) { cnn.scalar("SELECT ?::INTEGER[3]", [1, 2]) }
      expect_raises(DuckDB::Exception, /requires 3 elements/) { cnn.appender("arrays") { |a| a.row { |r| r << [1, 2] } } }
    end
  end

  it "checks STRUCT names and count, reorders fields and supports NamedTuple" do
    with_cnn do |cnn|
      type = "STRUCT(a BIGINT, b VARCHAR)"
      cnn.scalar("SELECT ?::#{type}", {b: "two", a: 1}).should eq({"a" => 1_i64, "b" => "two"})
      cnn.scalar("SELECT ?::#{type}", {"b" => "two", "a" => 1}).should eq({"a" => 1_i64, "b" => "two"})
      cnn.exec "CREATE TABLE structs (v #{type})"
      cnn.appender("structs") { |a| a.row { |r| r << {b: "two", a: 1} } }
      [{"a" => 1}, {"a" => 1, "b" => 2, "extra" => 3}, {"a" => 1, "wrong" => 2}, {"A" => 1, "b" => 2}].each do |invalid|
        expect_raises(DuckDB::Exception, /STRUCT/) { cnn.scalar("SELECT ?::#{type}", invalid) }
        expect_raises(DuckDB::Exception, /STRUCT/) { cnn.appender("structs") { |a| a.row { |r| r << invalid } } }
      end
      cnn.scalar("SELECT ?", {a: 1, b: [nil, 2]}).should eq({"a" => 1, "b" => [nil, 2]})
    end
  end

  it "keeps earlier results alive across cached re-execution and a conversion retry" do
    with_cnn do |cnn|
      statement = cnn.prepared("SELECT ?::INTEGER[]")
      first = statement.query([1, nil])
      expect_raises(DuckDB::Exception) { statement.query(["bad"]) }
      second = statement.query([2, 3])
      first.move_next.should be_true
      first.read.should eq([1, nil])
      second.move_next.should be_true
      second.read.should eq([2, 3])
    ensure
      first.try &.close
      second.try &.close
    end
  end

  it "retries rejected stale STRUCT metadata and rebinds all arguments from the first" do
    with_cnn do |cnn|
      cnn.exec "CREATE TABLE changing (id BIGINT NOT NULL, v DECIMAL(4,2)[])"
      statement = cnn.prepared("INSERT INTO changing VALUES (?, ?)")
      cnn.exec "CREATE OR REPLACE TABLE changing (id BIGINT NOT NULL, v STRUCT(a INTEGER[]))"
      before = native_lifetime { NativeLifetime.preparations }
      statement.exec(42_i64, {a: [1, nil]})
      native_lifetime { NativeLifetime.preparations.should eq(before + 1) }
      cnn.query("SELECT * FROM changing") do |rs|
        rs.move_next.should be_true
        rs.read.should eq(42_i64)
        rs.read.should eq({"a" => [1, nil]})
      end
    end
  end

  it "retries a stale precision rejection when the new column can represent the value" do
    with_cnn do |cnn|
      cnn.exec "CREATE TABLE changing (v DECIMAL(4,1)[])"
      statement = cnn.prepared("INSERT INTO changing VALUES (?)")
      cnn.exec "ALTER TABLE changing ALTER v TYPE DECIMAL(4,2)[]"
      before = native_lifetime { NativeLifetime.preparations }
      statement.exec([DuckDB::Decimal.new(125_i128, 4, 2)])
      native_lifetime { NativeLifetime.preparations.should eq(before + 1) }
      cnn.scalar("SELECT v FROM changing").should eq([DuckDB::Decimal.new(125_i128, 4, 2)])
    end
  end

  it "leaves accepted stale DECIMAL metadata to DuckDB's lossy execution cast" do
    with_cnn do |cnn|
      cnn.exec "CREATE TABLE changing (v DECIMAL(4,2)[])"
      statement = cnn.prepared("INSERT INTO changing VALUES (?)")
      cnn.exec "CREATE OR REPLACE TABLE changing (v DECIMAL(4,1)[])"
      before = native_lifetime { NativeLifetime.preparations }
      statement.exec([DuckDB::Decimal.new(125_i128, 4, 2)])
      native_lifetime { NativeLifetime.preparations.should eq(before) }
      cnn.scalar("SELECT v FROM changing").should eq([DuckDB::Decimal.new(13_i128, 4, 1)])
    end
  end

  it "pins the version-dependent lossy timestamp cast when stale metadata accepts it" do
    with_cnn do |cnn|
      modern = cnn.scalar("SELECT version()").as(String).starts_with?("v2.")
      cnn.exec "CREATE TABLE changing (v TIMESTAMP_NS)"
      statement = cnn.prepared("INSERT INTO changing VALUES (?)")
      cnn.exec "ALTER TABLE changing ALTER v TYPE TIMESTAMP"
      before = native_lifetime { NativeLifetime.preparations }
      statement.exec(DuckDB::Timestamp.from_nanoseconds(123456789_i128))
      native_lifetime { NativeLifetime.preparations.should eq(before) }
      expected = DuckDB::Timestamp.from_nanoseconds(modern ? 123457000_i128 : 123456000_i128)
      cnn.scalar("SELECT v FROM changing").should eq(expected)
    end
  end

  it "retries stale scalar precision checks without losing exact values" do
    with_cnn do |cnn|
      {
        "DECIMAL(4,1)" => {"DECIMAL(4,2)", DuckDB::Decimal.new(125_i128, 4, 2)},
        "TIMESTAMP" => {"TIMESTAMP_NS", DuckDB::Timestamp.from_nanoseconds(1_i128)},
        "TIME" => {"TIME_NS", DuckDB::TimeOfDay.from_nanoseconds(1_i64)},
      }.each do |old_type, entry|
        new_type, value = entry
        cnn.exec "CREATE OR REPLACE TABLE scalar_changing (v #{old_type})"
        statement = cnn.build_prepared_statement("INSERT INTO scalar_changing VALUES (?)")
        begin
          cnn.exec "CREATE OR REPLACE TABLE scalar_changing (v #{new_type})"
          before = native_lifetime { NativeLifetime.preparations }
          statement.exec(value)
          native_lifetime { NativeLifetime.preparations.should eq(before + 1) }
          cnn.scalar("SELECT v FROM scalar_changing").should eq(value)
        ensure
          statement.close
        end
      end
    end
  end

  it "raises the second conversion error after refreshing stale metadata" do
    with_cnn do |cnn|
      cnn.exec "CREATE TABLE second_error (v STRUCT(a INTEGER))"
      statement = cnn.prepared("INSERT INTO second_error VALUES (?)")
      cnn.exec "CREATE OR REPLACE TABLE second_error (v STRUCT(b INTEGER, c INTEGER))"
      before = native_lifetime { NativeLifetime.preparations }
      expect_raises(DuckDB::Exception, /STRUCT requires 2 fields, got 1/) { statement.exec({c: 1}) }
      native_lifetime { NativeLifetime.preparations.should eq(before + 1) }
    end
  end

  it "retains fixed-width scalar binds and never refreshes ordinary cached executions" do
    with_cnn do |cnn|
      statement = cnn.prepared("SELECT ?::TIMESTAMP, ?::DECIMAL(18,3), ?::TIME")
      timestamp = DuckDB::Timestamp.new(123456_i64)
      decimal = DuckDB::Decimal.new(123456_i128, 18, 3)
      time = DuckDB::TimeOfDay.new(123456_i64)
      before = native_lifetime { {NativeLifetime.preparations, NativeLifetime.timestamp_binds, NativeLifetime.decimal_binds, NativeLifetime.time_binds} }
      3.times { statement.exec(timestamp, decimal, time) }
      native_lifetime { NativeLifetime.preparations.should eq(before[0]) }
      native_lifetime { NativeLifetime.timestamp_binds.should eq(before[1] + 3) }
      native_lifetime { NativeLifetime.decimal_binds.should eq(before[2] + 3) }
      native_lifetime { NativeLifetime.time_binds.should eq(before[3] + 3) }
    end
  end

  it "checks scalar precision again after a successful cached execution" do
    with_cnn do |cnn|
      {
        "DECIMAL(4,1)" => {DuckDB::Decimal.new(120_i128, 4, 2), DuckDB::Decimal.new(125_i128, 4, 2)},
        "TIMESTAMP" => {DuckDB::Timestamp.new(1_i64), DuckDB::Timestamp.from_nanoseconds(1_i128)},
        "TIME" => {DuckDB::TimeOfDay.new(1_i64), DuckDB::TimeOfDay.from_nanoseconds(1_i64)},
      }.each do |type, values|
        valid, invalid = values
        statement = cnn.prepared("SELECT ?::#{type}")
        statement.exec(valid)
        before = native_lifetime { NativeLifetime.preparations }
        expect_raises(DuckDB::Exception, /precision|fractional/) { statement.exec(invalid) }
        native_lifetime { NativeLifetime.preparations.should eq(before + 1) }
      end
    end
  end

  native_lifetime_it "refreshes at most once for invalid conversions and does not retry native bind errors" do
    DB.connect "duckdb::memory:?prepared_statements_cache=false" do |cnn|
      statement = cnn.prepared("SELECT ?::INTEGER[2]")
      before = NativeLifetime.preparations
      expect_raises(DuckDB::Exception, /requires 2 elements/) { statement.exec([1]) }
      NativeLifetime.preparations.should eq(before + 1)
      statement = cnn.prepared("SELECT ?::INTEGER[]")
      before = NativeLifetime.preparations
      NativeLifetime.fail_bind_value(1)
      expect_raises(DuckDB::Exception, /Failed to bind/) { statement.exec([1, 2]) }
      NativeLifetime.preparations.should eq(before)
      statement = cnn.prepared("SELECT ?::VARCHAR")
      before = NativeLifetime.preparations
      expect_raises(DuckDB::Exception, /Failed to bind/) { statement.exec(String.new(Bytes[255])) }
      NativeLifetime.preparations.should eq(before)
      expect_raises(DuckDB::Exception, /Expected 1 arguments/) { statement.exec([1], [2]) }
      NativeLifetime.preparations.should eq(before)
    end
  ensure
    NativeLifetime.fail_bind_value(0)
  end

  it "infers static nullable types and nested containers, including empty ones" do
    with_cnn do |cnn|
      cnn.scalar("SELECT typeof(?)", [] of Int64).should eq("BIGINT[]")
      cnn.scalar("SELECT typeof(?)", [nil] of Int32?).should eq("INTEGER[]")
      cnn.scalar("SELECT ?", [] of Array(Int32)).should eq([] of DuckDB::Value)
      cnn.scalar("SELECT typeof(?)", {} of String => Int32).should eq("MAP(VARCHAR, INTEGER)")
      cnn.scalar("SELECT ?", [nil, 1_i64] of DuckDB::Value).should eq([nil, 1_i64])
      cnn.scalar("SELECT typeof(?)", {"a" => 1}).should eq("MAP(VARCHAR, INTEGER)")
      cnn.scalar("SELECT ?", [1, "2"] of DuckDB::Value).should eq([1, 2])
      cnn.scalar("SELECT ? = ANY(?)", [1, 2], [[1, 2], [3, 4]]).should be_true
      cnn.scalar("SELECT ? = ANY([])", [1, 2]).should be_false
      expect_raises(DuckDB::Exception) { cnn.scalar("SELECT ?", [1, "bad"] of DuckDB::Value) }
      [[] of DuckDB::Value, [nil] of DuckDB::Value, [] of Nil].each do |values|
        expect_raises(DuckDB::Exception, /Cannot infer/) { cnn.scalar("SELECT ?", values) }
        cnn.scalar("SELECT ?::INTEGER[]", values).should eq(values)
      end
      expect_raises(DuckDB::Exception, /Cannot infer/) { cnn.scalar("SELECT ?", {} of DuckDB::Value => DuckDB::Value) }
      expect_raises(DuckDB::Exception, /Cannot infer/) { cnn.scalar("SELECT ?", [] of DuckDB::Decimal) }
    end
  end

  it "rejects NULL map keys and keys that collide after native casting" do
    with_cnn do |cnn|
      expect_raises(DuckDB::Exception, /keys cannot be NULL/) { cnn.scalar("SELECT ?::MAP(INTEGER, INTEGER)", {nil => 1}) }
      expect_raises(DuckDB::Exception) { cnn.scalar("SELECT ?::MAP(INTEGER, INTEGER)", {"1" => 1, "01" => 2}) }
      nested_round_trip(cnn, "MAP(INTEGER, INTEGER)", {} of Int32 => Int32)
    end
  end

  it "round trips recursive read unions with NULLs at every level" do
    with_cnn do |cnn|
      {
        "INTEGER[][]"                                     => "[[1,NULL],NULL,[]]",
        "STRUCT(a INTEGER)[]"                             => "[{'a':1},NULL,{'a':NULL::INTEGER}]",
        "MAP(INTEGER, INTEGER[])"                         => "map([1,2,3], [[NULL,3],NULL,[]])",
        "STRUCT(a INTEGER[3], b MAP(VARCHAR, INTEGER[]))" => "{'a':[1,NULL,3]::INTEGER[3], 'b':map(['x','y'], [[NULL,2],NULL])}",
        "STRUCT(a INTEGER[], b INTEGER)"                  => "{'a':NULL::INTEGER[], 'b':NULL::INTEGER}",
        "UNION(a INTEGER,b VARCHAR)[]"                    => "[union_value(a:=42)::UNION(a INTEGER,b VARCHAR),union_value(b:='text'),NULL,union_value(a:=NULL::INTEGER)]",
        "INTEGER[2][]"                                    => "[[1,NULL]::INTEGER[2],NULL,[2,3]::INTEGER[2]]",
        "MAP(VARCHAR, STRUCT(x INTEGER[]))"               => "map(['a','b'], [{'x':[1,NULL]},NULL])",
      }.each do |type, expression|
        value = cnn.scalar("SELECT #{expression}")
        nested_round_trip(cnn, type, value)
        nested_round_trip(cnn, type, nil)
      end
    end
  end

  it "selects a unique exact UNION member and rejects missing or ambiguous matches" do
    with_cnn do |cnn|
      cnn.scalar("SELECT ?::UNION(a INTEGER,b VARCHAR)[]", [1, "text", nil] of DuckDB::Value).should eq([1, "text", nil])
      cnn.scalar("SELECT ?::UNION(a INTEGER[],b VARCHAR)[]", [[1, 2]]).should eq([[1, 2]])
      expect_raises(DuckDB::Exception, /exact logical-type match/) { cnn.scalar("SELECT ?::UNION(a BIGINT,b VARCHAR)[]", [1]) }
      expect_raises(DuckDB::Exception, /found 2/) { cnn.scalar("SELECT ?::UNION(a INTEGER,b INTEGER)[]", [1]) }
    end
  end

  it "rejects lossy nested decimal and temporal destinations before native casts" do
    with_cnn do |cnn|
      {
        "DECIMAL(4,1)[]" => [DuckDB::Decimal.new(123_i128, 4, 2)],
        "BIGINT[]"       => [DuckDB::Decimal.new(123_i128, 4, 2)],
        "DOUBLE[]"       => [DuckDB::Decimal.new(123_i128, 4, 2)],
        "TIMESTAMP[]"    => [DuckDB::Timestamp.from_nanoseconds(1_i128)],
        "TIMESTAMP_MS[]" => [DuckDB::Timestamp.from_nanoseconds(1000_i128)],
        "TIMESTAMP_S[]"  => [DuckDB::Timestamp.from_nanoseconds(1_000_000_i128)],
        "TIME[]"         => [DuckDB::TimeOfDay.from_nanoseconds(1_i64)],
      }.each do |type, value|
        cnn.exec "CREATE OR REPLACE TABLE lossy (v #{type})"
        expect_raises(DuckDB::Exception, /precision|fractional|exactness/) { cnn.scalar("SELECT ?::#{type}", value) }
        expect_raises(DuckDB::Exception, /precision|fractional|exactness/) { cnn.appender("lossy") { |a| a.row { |r| r << value } } }
      end
      cnn.scalar("SELECT ?::DECIMAL(4,1)[]", [DuckDB::Decimal.new(1230_i128, 4, 2)]).should eq([DuckDB::Decimal.new(123_i128, 4, 1)])
      time = Time.unix(-1) + 999_999_999.nanoseconds
      cnn.scalar("SELECT ?::TIMESTAMP_NS[]", [time]).should eq([DuckDB::Timestamp.new(time)])
    end
  end

  it "tracks scalar and nested columns across rows, including UTC Time leaves and partial-row errors" do
    DB.connect "duckdb::memory:?prepared_statements_cache=false" do |base|
      cnn = base.as(DuckDB::Connection)
      cnn.exec "CREATE TABLE mixed_nested (id BIGINT, xs INTEGER[], m MAP(VARCHAR, INTEGER[]), s STRUCT(t TIMESTAMP_NS, a BIGINT[2]))"
      time = Time.unix(-1) + 999_999_999.nanoseconds
      before = native_lifetime { nested_handles }
      cnn.appender("mixed_nested") do |a|
        3.times { |i| a.row { |r| r << i.to_i64 << [1, nil] << {"x" => [2, nil]} << {t: time, a: [3, nil]} } }
      end
      cnn.query("SELECT * FROM mixed_nested ORDER BY id") do |rs|
        3.times do |i|
          rs.move_next.should be_true
          rs.read.should eq(i)
          rs.read.should eq([1, nil])
          rs.read.should eq({"x" => [2, nil]})
          rs.read.should eq({"t" => DuckDB::Timestamp.new(time), "a" => [3_i64, nil]})
        end
      end
      expect_raises(DuckDB::Exception) do
        cnn.appender("mixed_nested") do |a|
          a.begin_row
          a << 4_i64 << [1, nil] << {"x" => [2, "bad"]}
        end
      end
      native_lifetime { nested_handles.should eq(before) }
    end
  end

  it "cleans successful and failed binds, native casts, partial rows and deep errors" do
    DB.connect "duckdb::memory:?prepared_statements_cache=false" do |base|
      cnn = base.as(DuckDB::Connection)
      cnn.exec "CREATE TABLE deep (v STRUCT(a INTEGER[], b STRUCT(x DECIMAL(4,1))))"
      cnn.exec "CREATE TABLE cast_error (v UUID)"
      before = native_lifetime { nested_handles }
      3.times do
        value = {a: [1, nil], b: {x: DuckDB::Decimal.new(120_i128, 4, 2)}}
        cnn.exec("INSERT INTO deep VALUES (?)", value)
        cnn.appender("deep") { |a| a.row { |r| r << value } }
        bad = {a: [1, nil], b: {x: DuckDB::Decimal.new(123_i128, 4, 2)}}
        expect_raises(DuckDB::Exception) { cnn.exec("INSERT INTO deep VALUES (?)", bad) }
        expect_raises(DuckDB::Exception) { cnn.appender("deep") { |a| a.row { |r| r << bad } } }
        expect_raises(DuckDB::Exception) { cnn.scalar("SELECT ?::INTEGER[][]", [[1], ["bad"]]) }
        expect_raises(DuckDB::Exception) { cnn.appender("cast_error") { |a| a.row { |r| r << [1] } } }
        native_lifetime { nested_handles.should eq(before) }
      end
      a = cnn.appender("deep")
      a.close
      expect_raises(DuckDB::Exception, /closed/) { a << {a: [1], b: {x: 1}} }
      native_lifetime { nested_handles.should eq(before) }
    end
  end
end

describe "DuckDB nested construction failures" do
  native_lifetime_it "releases every preceding allocation when any constructor fails" do
    before = nested_handles
    value = [{a: [1, nil, 2], b: {"x" => [3, 4]}}]
    [false, true].each do |fail_types|
      succeeded = false
      100.times do |position|
        begin
          fail_types ? NativeLifetime.fail_type_after(position) : NativeLifetime.fail_value_after(position)
          native = DuckDB::ValueBuilder.build(value)
          DuckDB::LibDuckDB.destroy_value(pointerof(native))
          succeeded = true
        rescue DuckDB::Exception
        ensure
          NativeLifetime.fail_type_after(-1)
          NativeLifetime.fail_value_after(-1)
        end
        nested_handles.should eq(before)
        break if succeeded
      end
      succeeded.should be_true
    end
  end

  native_lifetime_it "destroys a completed root when native binding or appending fails" do
    DB.connect "duckdb::memory:?prepared_statements_cache=false" do |base|
      cnn = base.as(DuckDB::Connection)
      cnn.exec "CREATE TABLE root_failure (v STRUCT(a INTEGER[]))"
      before = nested_handles
      NativeLifetime.fail_bind_value(1)
      expect_raises(DuckDB::Exception) { cnn.exec "INSERT INTO root_failure VALUES (?)", {a: [1, nil, 2]} }
      NativeLifetime.fail_append_value(1)
      expect_raises(DuckDB::Exception, /Failed to append/) { cnn.appender("root_failure") { |a| a.row { |r| r << {a: [1, nil, 2]} } } }
      bad_utf8 = String.new(Bytes[255])
      expect_raises(DuckDB::Exception) { cnn.scalar("SELECT ?::STRUCT(a INTEGER[], b VARCHAR)", {a: [1, 2], b: bad_utf8}) }
      nested_handles.should eq(before)
    end
  ensure
    NativeLifetime.fail_bind_value(0)
    NativeLifetime.fail_append_value(0)
  end
end

describe "DuckDB nanosecond timezone binding" do
  it "resolves the optional constructor once, binds, appends and nests exact TZ values" do
    DB.connect "duckdb::memory:?prepared_statements_cache=false" do |base|
      cnn = base.as(DuckDB::Connection)
      modern = cnn.scalar("SELECT version()").as(String).starts_with?("v2.")
      before = native_lifetime { nested_handles }
      [1_i128, -1_i128, 123456789_i128].each do |nanos|
        value = DuckDB::Timestamp.from_nanoseconds(nanos, timezone: true)
        if modern
          actual = cnn.scalar("SELECT ?", value).as(DuckDB::Timestamp)
          actual.should eq(value)
          actual.timezone?.should be_true
          cnn.scalar("SELECT ?::TIMESTAMPTZ_NS", value).should eq(value)
          nested_round_trip(cnn, "TIMESTAMPTZ_NS[]", [value, nil])
          nested_round_trip(cnn, "TIMESTAMPTZ_NS", value)
          expect_raises(DuckDB::Exception, /lose precision/) { cnn.scalar("SELECT ?::TIMESTAMPTZ", value) }
        else
          expect_raises(DuckDB::Exception, /unavailable.*DuckDB 2.0/) { cnn.scalar("SELECT ?", value) }
          expect_raises(DuckDB::Exception, /unavailable/) { cnn.scalar("SELECT ?::TIMESTAMP_NS[]", [value]) }
          cnn.exec "CREATE OR REPLACE TABLE tz_missing (v TIMESTAMP_NS[])"
          expect_raises(DuckDB::Exception, /unavailable/) { cnn.appender("tz_missing") { |a| a.row { |r| r << [value] } } }
        end
        native_lifetime { nested_handles.should eq(before) }
      end
      native_lifetime { NativeLifetime.tz_ns_lookups.should eq(1) }
    end
  end
end
