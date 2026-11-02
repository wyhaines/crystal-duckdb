require "../spec_helper"
require "../support/lifecycle"

describe "DuckDB exact appending" do
  it "appends Time.utc to the README's plain TIMESTAMP column" do
    with_cnn do |cnn|
      cnn.exec "CREATE TABLE times (v TIMESTAMP)"
      time = Time.utc
      cnn.appender("times") { |a| a.row { |row| row << time } }
      cnn.scalar("SELECT v FROM times").should eq(cnn.scalar("SELECT ?::TIMESTAMP", time))
    end
  end

  {% for type in %w(TIMESTAMP TIMESTAMP_NS TIMESTAMP_S TIMESTAMP_MS TIMESTAMPTZ) %}
    it "lets DuckDB cast submicrosecond Time to {{type.id}}" do
      with_cnn do |cnn|
        cnn.exec "SET TimeZone='UTC'"
        cnn.exec "CREATE TABLE times (v {{type.id}})"
        [Time.utc(2026, 1, 2, 3, 4, 5, nanosecond: 123456789), Time.unix(-1) + 999_999_999.nanoseconds].each do |time|
          {% if type == "TIMESTAMP_S" || type == "TIMESTAMP_MS" %}
            if {{type}} == "TIMESTAMP_S" || cnn.scalar("SELECT version()").as(String).starts_with?("v1.")
              expect_raises(DuckDB::Exception, /Failed to append/) do
                cnn.appender("times") { |a| a.row { |row| row << time } }
              end
              next
            end
          {% end %}
          cnn.appender("times") { |a| a.row { |row| row << time } }
        end
        {% if type == "TIMESTAMP_S" || type == "TIMESTAMP_MS" %}
          next if {{type}} == "TIMESTAMP_S" || cnn.scalar("SELECT version()").as(String).starts_with?("v1.")
        {% end %}
        cnn.query("SELECT v FROM times") do |rs|
          [Time.utc(2026, 1, 2, 3, 4, 5, nanosecond: 123456789), Time.unix(-1) + 999_999_999.nanoseconds].each do |time|
            rs.move_next.should be_true
            rs.read.should eq(cnn.scalar("SELECT ?::{{type.id}}", time))
          end
        end
      end
    end
  {% end %}
end

native_lifetime do
  private def appender_handles
    {NativeLifetime.values, NativeLifetime.logical_types, NativeLifetime.appenders}
  end
end

describe "DuckDB appender exact types and identifiers" do
  {% for type in %w(TIME TIME_NS) %}
    it "appends exact TimeOfDay into {{type.id}} and rejects loss of precision" do
      with_cnn do |cnn|
        cnn.exec "CREATE TABLE times (v {{type.id}})"
        value = DuckDB::TimeOfDay.new("12:34:56.123456789")
        {% if type == "TIME_NS" %}
          cnn.appender("times") { |a| a.row { |r| r << value } }
          cnn.scalar("SELECT v FROM times").should eq(value)
        {% else %}
          expect_raises(DuckDB::Exception, /lose precision/) { cnn.appender("times") { |a| a.row { |r| r << value } } }
        {% end %}
        aligned = DuckDB::TimeOfDay.new(24, 0)
        cnn.appender("times") { |a| a.row { |r| r << aligned } }
      end
    end
  {% end %}

  {% for type in %w(TIMESTAMP TIMESTAMP_NS TIMESTAMP_S TIMESTAMP_MS TIMESTAMPTZ) %}
    it "enforces exact wrapper precision and preserves infinity in {{type.id}}" do
      with_cnn do |cnn|
        cnn.exec "SET TimeZone='UTC'"
        cnn.exec "CREATE TABLE times (v {{type.id}})"
        value = DuckDB::Timestamp.from_nanoseconds(123456789_i128)
        {% if type == "TIMESTAMP_NS" %}
          cnn.appender("times") { |a| a.row { |r| r << value } }
          cnn.scalar("SELECT v FROM times").should eq(value)
        {% else %}
          expect_raises(DuckDB::Exception, /lose precision/) { cnn.appender("times") { |a| a.row { |r| r << value } } }
        {% end %}
        %w(infinity -infinity).each do |text|
          value = cnn.scalar("SELECT '#{text}'::{{type.id}}").as(DuckDB::Timestamp)
          cnn.appender("times") { |a| a.row { |r| r << value } }
        end
        aligned = DuckDB::Timestamp.new(Time.utc(2026, 1, 1))
        cnn.appender("times") { |a| a.row { |r| r << aligned } }
        values = cnn.query_all("SELECT v FROM times", as: DuckDB::Timestamp)
        values[-3].should eq(DuckDB::Timestamp.new("infinity"))
        values[-2].should eq(DuckDB::Timestamp.new("-infinity"))
        values[-1].should eq(aligned)
      end
    end
  {% end %}

  it "round trips DECIMAL storage widths and extrema without floats" do
    with_cnn do |cnn|
      before = native_lifetime { appender_handles }
      [4, 9, 18, 38].each do |width|
        [0, 2, width].each do |scale|
          cnn.exec "CREATE OR REPLACE TABLE decimals (v DECIMAL(#{width},#{scale}))"
          limit = 10_i128 ** width - 1
          expected = [-limit, -1_i128, 0_i128, 1_i128, limit].map { |v| DuckDB::Decimal.new(v, width, scale) }
          cnn.appender("decimals") do |a|
            expected.each { |v| a.row { |r| r << v } }
            a.row { |r| r << nil }
          end
          cnn.query_all("SELECT v FROM decimals", as: DuckDB::Decimal?).should eq(expected + [nil])
        end
      end
      native_lifetime { appender_handles.should eq(before) }
    end
  end

  it "rejects lossy decimal scale reduction and releases values when native casts fail" do
    with_cnn do |cnn|
      cnn.exec "CREATE TABLE decimals (v DECIMAL(4,1))"
      before = native_lifetime { appender_handles }
      expect_raises(DuckDB::Exception, /lose fractional digits/) do
        cnn.appender("decimals") { |a| a.row { |r| r << DuckDB::Decimal.new(123_i128, 4, 2) } }
      end
      cnn.appender("decimals") { |a| a.row { |r| r << DuckDB::Decimal.new(1230_i128, 4, 2) } }
      cnn.scalar("SELECT v FROM decimals").should eq(DuckDB::Decimal.new(123_i128, 4, 1))
      cnn.exec "CREATE TABLE invalid (v UUID)"
      expect_raises(DuckDB::Exception) do
        cnn.appender("invalid") { |a| a.row { |r| r << DuckDB::Decimal.new(123_i128, 4, 2) } }
      end
      native_lifetime { appender_handles.should eq(before) }
    end
  end

  it "rejects fractional decimals in integral columns, and checks the current column across rows" do
    with_cnn do |cnn|
      cnn.exec "CREATE TABLE mixed (n BIGINT, d DECIMAL(6,2), t TIMESTAMP_NS, label VARCHAR)"
      exact = DuckDB::Timestamp.from_nanoseconds(123456789_i128)
      cnn.appender("mixed") do |a|
        3.times do |i|
          a.row { |r| r << i.to_i64 << DuckDB::Decimal.new(1230_i128, 4, 2) << exact << "a\0b" }
        end
      end
      cnn.query_all("SELECT t FROM mixed", as: DuckDB::Timestamp).should eq([exact] * 3)
      cnn.exec "CREATE TABLE integral (v BIGINT)"
      expect_raises(DuckDB::Exception, /lose fractional digits/) do
        cnn.appender("integral") { |a| a.row { |r| r << DuckDB::Decimal.new(123_i128, 4, 2) } }
      end
    end
  end

  it "destroys new values on closed appenders and rejects unsupported TZ nanoseconds" do
    with_cnn do |cnn|
      cnn.exec "CREATE TABLE exact_values (v TIMESTAMPTZ)"
      before = native_lifetime { appender_handles }
      appender = cnn.appender("exact_values")
      appender.close
      expect_raises(DuckDB::Exception, /closed/) { appender << UUID.random }
      expect_raises(DuckDB::Exception, /closed/) { appender << DuckDB::BigNum.new(Bytes[0x80, 0, 1, 42]) }
      cnn.exec "CREATE TABLE tz_ns (v TIMESTAMP_NS)"
      value = DuckDB::Timestamp.from_nanoseconds(1_i128, timezone: true)
      expect_raises(DuckDB::Exception, /unavailable/) { cnn.appender("tz_ns") { |a| a.row { |r| r << value } } }
      native_lifetime { appender_handles.should eq(before) }
    end
  end

  it "round trips UUID, UInt128, infinite Date, TZ timestamp, TimeTZ, BigNum and BIT" do
    with_cnn do |cnn|
      before = native_lifetime { appender_handles }
      {
        "UUID" => [UUID.new("00000000-0000-0000-0000-000000000000"), UUID.new("ffffffff-ffff-ffff-ffff-ffffffffffff")],
        "UHUGEINT" => [0_u128, UInt128::MAX],
        "DATE" => [DuckDB::Date.new("infinity"), DuckDB::Date.new("-infinity"), DuckDB::Date.new(-719528)],
        "TIMESTAMPTZ" => [DuckDB::Timestamp.from_raw(1_i64, DuckDB::Type::TIMESTAMP_TZ), DuckDB::Timestamp.from_raw(Int64::MAX, DuckDB::Type::TIMESTAMP_TZ)],
        "TIMETZ" => [DuckDB::TimeTZ.new(DuckDB::TimeOfDay.new(24, 0), -19801)],
        "BIGNUM" => [cnn.scalar("SELECT ?::BIGNUM", "-" + "9" * 1000).as(DuckDB::BigNum), cnn.scalar("SELECT ?::BIGNUM", "9" * 1000).as(DuckDB::BigNum)],
        "BIT" => ["0", "1", "101", "01" * 100],
      }.each do |type, values|
        cnn.exec "CREATE OR REPLACE TABLE exact_values (v #{type})"
        cnn.appender("exact_values") { |a| values.each { |v| a.row { |r| r << v } }; a.row { |r| r << nil } }
        actual = cnn.query_all("SELECT v FROM exact_values") { |rs| rs.read }
        actual.should eq(values + [nil])
        native_lifetime { appender_handles.should eq(before) }
      end
    end
  end

  it "supports literal names, schemas and attached catalogs without SQL quoting" do
    with_cnn do |cnn|
      cnn.unprepared.exec %(CREATE SCHEMA "odd.schema"; CREATE TABLE "odd.schema"."a.b" (v BIGINT); CREATE TABLE "select" (v BIGINT); CREATE TABLE "a\"\"b" (v BIGINT))
      cnn.appender("a.b", schema: "odd.schema") { |a| a.row { |r| r << 1_i64 } }
      cnn.appender("select") { |a| a.row { |r| r << 2_i64 } }
      cnn.appender("a\"b") { |a| a.row { |r| r << 3_i64 } }
      cnn.scalar(%(SELECT v FROM "odd.schema"."a.b")).should eq(1_i64)
      cnn.scalar(%(SELECT v FROM "select")).should eq(2_i64)
      cnn.scalar(%(SELECT v FROM "a\"\"b")).should eq(3_i64)
      cnn.unprepared.exec %(ATTACH ':memory:' AS "other.catalog"; CREATE SCHEMA "other.catalog"."s.s"; CREATE TABLE "other.catalog"."s.s"."t.t" (v INTEGER))
      appender = cnn.appender("t.t", "s.s", "other.catalog")
      appender.row { |r| r << 42 }
      appender.close
      cnn.scalar(%(SELECT v FROM "other.catalog"."s.s"."t.t")).should eq(42)
      expect_raises(DuckDB::Exception) { cnn.appender("odd.schema.a.b") }
    end
  end

  it "rejects NUL bytes in every identifier before opening an appender" do
    with_cnn do |cnn|
      cnn.exec "CREATE TABLE plain (v INTEGER)"
      before = native_lifetime { appender_handles }
      expect_raises(DuckDB::Exception, /NUL/) { cnn.appender("plain\0ignored") }
      expect_raises(DuckDB::Exception, /NUL/) { cnn.appender("plain", "main\0ignored") }
      expect_raises(DuckDB::Exception, /NUL/) { cnn.appender("plain", catalog: "memory\0ignored") { |_| } }
      native_lifetime { appender_handles.should eq(before) }
      cnn.scalar("SELECT count(*) FROM plain").should eq(0)
    end
  end
end

describe "DuckDB native appender temporal casts" do
  # The public TimeOfDay policy rejects precision loss. Probe DuckDB's native
  # cast independently, so its TIME/TIME_NS behavior is pinned on both engines.
  {% for type in %w(TIME TIME_NS) %}
    it "casts an exact TIME_NS value to {{type.id}} in DuckDB itself" do
      with_cnn do |cnn|
        cnn.exec "CREATE TABLE native_times (v {{type.id}})"
        before = native_lifetime { appender_handles }
        value = DuckDB::LibDuckDB.create_time_ns(DuckDB::LibDuckDB::TimeNS.new(nanos: 45_296_123_456_789_i64))
        state = DuckDB::LibDuckDB.appender_create_ext(cnn, nil, nil, "native_times", out appender)
        begin
          state.success?.should be_true
          DuckDB::LibDuckDB.append_value(appender, value).success?.should be_true
          DuckDB::LibDuckDB.appender_end_row(appender).success?.should be_true
          DuckDB::LibDuckDB.appender_close(appender).success?.should be_true
          expected = {{type == "TIME" ? "12:34:56.123457" : "12:34:56.123456789"}}
          cnn.scalar("SELECT CAST(v AS VARCHAR) FROM native_times").should eq(expected)
        ensure
          DuckDB::LibDuckDB.appender_destroy(pointerof(appender))
          DuckDB::LibDuckDB.destroy_value(pointerof(value))
        end
        native_lifetime { appender_handles.should eq(before) }
      end
    end
  {% end %}
end
