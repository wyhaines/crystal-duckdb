require "../spec_helper"
require "../support/lifecycle"

macro typed_scalar(type, expression)
  it "reads {{type.id}} from {{expression.id}}, including nullable typed reads" do
    with_cnn do |cnn|
      value = cnn.scalar("SELECT " + {{expression}})
      value.should be_a({{type}})
      cnn.query("SELECT " + {{expression}} + ", NULL, " + {{expression}}) do |rs|
        rs.move_next
        rs.read({{type}}).should eq(value)
        rs.read({{type}}?).should be_nil
        rs.read({{type}}?).should eq(value)
      end
    end
  end
end

describe "DuckDB exact scalar types" do
  typed_scalar DuckDB::Decimal, "'-12.30'::DECIMAL(4,2)"
  typed_scalar UUID, "'ffffffff-ffff-ffff-ffff-ffffffffffff'::UUID"
  typed_scalar UInt128, "'340282366920938463463374607431768211455'::UHUGEINT"
  typed_scalar String, "'blue'::ENUM('red','blue')"
  typed_scalar String, "'101001'::BIT"
  typed_scalar DuckDB::BigNum, "'-12345678901234567890123456789012345678901234567890'::BIGNUM"
  typed_scalar Bytes, "'POINT (1 2)'::GEOMETRY"
  typed_scalar DuckDB::Date, "DATE '0001-01-01 (BC)'"
  typed_scalar DuckDB::TimeOfDay, "TIME '24:00:00'"
  typed_scalar DuckDB::TimeOfDay, "'12:34:56.123456789'::TIME_NS"
  typed_scalar DuckDB::TimeTZ, "TIMETZ '24:00:00+05:30:01'"
  typed_scalar DuckDB::Timestamp, "TIMESTAMP '1600-01-01 12:34:56.123456'"
  typed_scalar DuckDB::Timestamp, "'2300-01-01 12:34:56'::TIMESTAMP_S"
  typed_scalar DuckDB::Timestamp, "'2300-01-01 12:34:56.123'::TIMESTAMP_MS"
  typed_scalar DuckDB::Timestamp, "'1969-12-31 23:59:59.999999999'::TIMESTAMP_NS"
  typed_scalar DuckDB::Timestamp, "TIMESTAMPTZ '2300-01-01 12:34:56.123456+00'"
  typed_scalar DuckDB::Interval, "INTERVAL '2 months 3 days 4 microseconds'"

  it "reads TIMESTAMPTZ_NS on 2.0 with its exact nanoseconds" do
    with_cnn do |cnn|
      if cnn.scalar("SELECT version()").as(String).starts_with?("v2.")
        cnn.query("SELECT '1969-12-31 23:59:59.999999999+00'::TIMESTAMPTZ_NS, NULL::TIMESTAMPTZ_NS") do |rs|
          rs.move_next
          value = rs.read(DuckDB::Timestamp)
          value.nanoseconds.should eq(-1)
          value.timezone?.should be_true
          value.to_time.should eq(Time.unix(-1) + 999_999_999.nanoseconds)
          rs.read(DuckDB::Timestamp?).should be_nil
        end
      end
    end
  end

  it "round trips UUIDs and unsigned huge integers at both extrema" do
    with_cnn do |cnn|
      %w(00000000-0000-0000-0000-000000000000 7fffffff-ffff-ffff-ffff-ffffffffffff 80000000-0000-0000-0000-000000000000 ffffffff-ffff-ffff-ffff-ffffffffffff).each do |text|
        value = UUID.new(text)
        cnn.query("SELECT ?::UUID, CAST(?::UUID AS VARCHAR)", value, value) do |rs|
          rs.move_next
          rs.read(UUID).should eq(value)
          rs.read(String).should eq(value.to_s)
        end
        cnn.query("SELECT ?::UUID", value) { |rs| rs.move_next; rs.read(String).should eq(text) }
      end
      [0_u128, UInt128::MAX].each { |v| cnn.scalar("SELECT ?::UHUGEINT", v).should eq(v) }
      [Int128::MIN, -1_i128, 0_i128, Int128::MAX].each do |v|
        DuckDB::HugeIntHelper.huge_to_i128(DuckDB::HugeIntHelper.i128_to_huge(v)).should eq(v)
        cnn.scalar("SELECT ?::HUGEINT", v).should eq(v)
      end
    end
  end

  it "decodes BIT padding and long BIGNUM values exactly" do
    with_cnn do |cnn|
      ["0", "1", "101", "00000000", "101010101", "01" * 100].each do |text|
        cnn.query("SELECT ?::BIT, CAST(?::BIT AS VARCHAR)", text, text) do |rs|
          rs.move_next
          rs.read(String).should eq(rs.read(String))
        end
      end
      ["0", "1", "-1", "255", "-256", "9" * 1000, "-" + "9" * 1000].each do |text|
        value = cnn.scalar("SELECT ?::BIGNUM", text).as(DuckDB::BigNum)
        value.to_s.should eq(text)
        cnn.scalar("SELECT CAST(? AS VARCHAR)", value).should eq(text)
      end
    end
  end

  it "copies GEOMETRY WKB from a vector on both engines without an extension" do
    with_cnn do |cnn|
      bytes = cnn.scalar("SELECT 'POINT (1 2)'::GEOMETRY").as(Bytes)
      bytes.size.should eq(21)
      bytes[0, 5].should eq(Bytes[1, 1, 0, 0, 0])
      IO::ByteFormat::LittleEndian.decode(Float64, bytes[5, 8]).should eq(1.0)
      IO::ByteFormat::LittleEndian.decode(Float64, bytes[13, 8]).should eq(2.0)
    end
  end

  it "caches enum dictionaries for a column across chunks, including wider storage" do
    with_cnn do |cnn|
      dictionaries = native_lifetime { NativeLifetime.enum_dictionary_reads }
      cnn.query("SELECT CASE WHEN i % 2 = 0 THEN 'blue' ELSE NULL END::ENUM('red','blue') FROM range(5000) t(i)") do |rs|
        i = 0
        native_lifetime { NativeLifetime.enum_dictionary_reads.should eq(dictionaries + 2) }
        rs.each do
          rs.read(String?).should eq(i.even? ? "blue" : nil)
          i += 1
        end
        native_lifetime { NativeLifetime.enum_dictionary_reads.should eq(dictionaries + 2) }
      end
      names = (0..256).map { |i| "'v#{i}'" }.join(',')
      cnn.scalar("SELECT 'v256'::ENUM(#{names})").should eq("v256")
    end
  end
end

describe DuckDB::Decimal do
  it "matches DuckDB text and round trips storage widths 4, 9, 18 and 38, including extrema" do
    with_cnn do |cnn|
      [4, 9, 18, 38].each do |width|
        [0, 2, width].each do |scale|
          limit = 10_i128 ** width - 1
          [-limit, -1_i128, 0_i128, 1_i128, limit].each do |unscaled|
            value = DuckDB::Decimal.new(unscaled, width, scale)
            cnn.query("SELECT ?::DECIMAL(#{width},#{scale}), CAST(?::DECIMAL(#{width},#{scale}) AS VARCHAR)", value, value) do |rs|
              rs.move_next
              actual = rs.read(DuckDB::Decimal)
              actual.value.should eq(unscaled)
              actual.width.should eq(width)
              actual.scale.should eq(scale)
              actual.to_s.should eq(rs.read(String))
            end
            cnn.query("SELECT ?", value) { |rs| rs.move_next; rs.read(String).should eq(value.to_s) }
          end
        end
      end
    end
  end

  it "compares numerically without rescaling overflow and uses a matching hash" do
    a = DuckDB::Decimal.new(1230_i128, 4, 2)
    b = DuckDB::Decimal.new(123_i128, 3, 1)
    a.should eq(b)
    a.hash.should eq(b.hash)
    a.to_f64.should eq(12.3)
    DuckDB::Decimal.new(-1_i128, 1, 1).should be < DuckDB::Decimal.new(0_i128, 38, 38)
    DuckDB::Decimal.new(10_i128 ** 38 - 1, 38, 0).should be > DuckDB::Decimal.new(1_i128, 38, 38)
    expect_raises(ArgumentError) { DuckDB::Decimal.new(100_i128, 2, 0) }
    expect_raises(ArgumentError) { DuckDB::Decimal.new(0_i128, 2, 3) }
  end
end

describe "DuckDB nested values" do
  it "distinguishes empty, NULL, NULL elements and nested NULL lists" do
    with_cnn do |cnn|
      cnn.query("SELECT []::INTEGER[], NULL::INTEGER[], [1,NULL,3], [[1,NULL],NULL,[]]") do |rs|
        rs.move_next
        rs.read.should eq([] of DuckDB::Value)
        rs.read.should be_nil
        rs.read.should eq([1, nil, 3])
        rs.read.should eq([[1, nil], nil, [] of Int32])
      end
      cnn.query("SELECT [[1,NULL],NULL,[]], NULL::INTEGER[][]") do |rs|
        rs.move_next
        rs.read(Array(Array(Int32?)?)).should eq([[1, nil], nil, [] of Int32?])
        rs.read(Array(Array(Int32?)?)?).should be_nil
      end
    end
  end

  it "preserves struct field order and NULL fields and values" do
    with_cnn do |cnn|
      cnn.query("SELECT {'z':1,'a':NULL::INTEGER,'nested':[NULL,2]}, NULL::STRUCT(z INTEGER)") do |rs|
        rs.move_next
        value = rs.read.as(Hash(String, DuckDB::Value))
        value.keys.should eq(["z", "a", "nested"])
        value["a"].should be_nil
        value["nested"].should eq([nil, 2])
        rs.read.should be_nil
      end
      cnn.query("SELECT {'z':1,'a':NULL::INTEGER}, NULL::STRUCT(z INTEGER)") do |rs|
        rs.move_next
        rs.read(Hash(String, Int32?)).should eq({"z" => 1, "a" => nil})
        rs.read(Hash(String, Int32)?).should be_nil
      end
    end
  end

  it "reads MAP NULL values, nested values, empty maps and whole NULL maps" do
    with_cnn do |cnn|
      cnn.query("SELECT map(['a','b'], [1,NULL]), NULL::MAP(VARCHAR,INTEGER), map([]::VARCHAR[],[]::INTEGER[]), map([1,2], [[NULL,3],NULL])") do |rs|
        rs.move_next
        rs.read.should eq({"a" => 1, "b" => nil})
        rs.read.should be_nil
        rs.read.as(Hash(DuckDB::Value, DuckDB::Value)).empty?.should be_true
        rs.read.should eq({1 => [nil, 3], 2 => nil})
      end
      cnn.query("SELECT map(['a','b'], [1,NULL]), NULL::MAP(VARCHAR,INTEGER)") do |rs|
        rs.move_next
        rs.read(Hash(String, Int32?)).should eq({"a" => 1, "b" => nil})
        rs.read(Hash(String, Int32)?).should be_nil
      end
    end
  end

  it "uses fixed ARRAY stride and child validity across chunks" do
    with_cnn do |cnn|
      cnn.query("SELECT (CASE WHEN i % 3 = 0 THEN NULL ELSE [i,NULL,i+1] END)::BIGINT[3] FROM range(5000) t(i)") do |rs|
        i = 0_i64
        rs.each do
          rs.read(Array(Int64?)?).should eq(i % 3 == 0 ? nil : [i, nil, i + 1])
          i += 1
        end
      end
    end
  end

  it "returns the active UNION member, including an active NULL member" do
    with_cnn do |cnn|
      values = cnn.query_all("SELECT u FROM (VALUES (union_value(a := 42)::UNION(a INTEGER,b VARCHAR)), (union_value(b := 'text')), (union_value(a := NULL::INTEGER)), (NULL)) t(u)") { |rs| rs.read }
      values.should eq([42, "text", nil, nil])
    end
  end

  it "propagates NULL structs inside lists and keeps nested typed fields" do
    with_cnn do |cnn|
      cnn.query("SELECT [{'a':1},NULL,{'a':NULL::INTEGER}], {'a':[1,NULL]}, [1,NULL,3]::INTEGER[3]") do |rs|
        rs.move_next
        rs.read(Array(Hash(String, Int32?)?)).should eq([{"a" => 1}, nil, {"a" => nil}])
        rs.read(Hash(String, Array(Int32?))).should eq({"a" => [1, nil]})
        rs.read.should eq([1, nil, 3])
      end
    end
  end

  it "applies scalar String conversions inside typed containers" do
    with_cnn do |cnn|
      cnn.query("SELECT [1.20::DECIMAL(4,2),NULL], INTERVAL '1 day'") do |rs|
        rs.move_next
        rs.read(Array(String?)).should eq(["1.20", nil])
        rs.read(String).should eq(DuckDB::Interval.new(days: 1).to_s)
      end
    end
  end

  it "recovers from typed child mismatches at the next column" do
    with_cnn do |cnn|
      cnn.query("SELECT [1,NULL], 42") do |rs|
        rs.move_next
        expect_raises(DB::ColumnTypeMismatchError) { rs.read(Array(Int32)) }
        rs.read(Int32).should eq(42)
      end
    end
  end
end

describe "DuckDB type resource ownership" do
  it "destroys exact binding values and nested type trees, including read errors" do
    DB.connect "duckdb::memory:?prepared_statements_cache=false" do |cnn|
      before = native_lifetime { {NativeLifetime.values, NativeLifetime.logical_types, NativeLifetime.chunks, NativeLifetime.results, NativeLifetime.statements} }
      3.times do
        cnn.scalar("SELECT ?", UUID.new("80000000-0000-0000-0000-000000000001"))
        cnn.scalar("SELECT ?", DuckDB::TimeOfDay.new("12:34:56.123456789"))
        cnn.scalar("SELECT ?", DuckDB::TimeTZ.new(DuckDB::TimeOfDay.new(12, 0), 0))
        cnn.scalar("SELECT ?", DuckDB::Timestamp.from_nanoseconds(1_i128))
        cnn.scalar("SELECT ?::TIMESTAMP_S", DuckDB::Timestamp.from_raw(Int64::MAX - 1, DuckDB::LibDuckDB::Type::TIMESTAMP_S))
        cnn.scalar("SELECT ?::TIMESTAMP_MS", DuckDB::Timestamp.from_raw(Int64::MAX - 1, DuckDB::LibDuckDB::Type::TIMESTAMP_MS))
        cnn.scalar("SELECT ?", DuckDB::Timestamp.from_raw(1_i64, DuckDB::LibDuckDB::Type::TIMESTAMP_TZ))
        cnn.scalar("SELECT ?", DuckDB::BigNum.new(Bytes[0x80, 0, 1, 42]))
        cnn.scalar("SELECT [{'a':[1,NULL]},{'a':NULL}]")
        expect_raises(DuckDB::Exception, /VARIANT.*stable v1 C API/) { cnn.scalar("SELECT [42::VARIANT]") }
        cnn.scalar("SELECT NULL::VARIANT").should be_nil
        native_lifetime { {NativeLifetime.values, NativeLifetime.logical_types, NativeLifetime.chunks, NativeLifetime.results, NativeLifetime.statements}.should eq(before) }
      end
    end
  end
end
