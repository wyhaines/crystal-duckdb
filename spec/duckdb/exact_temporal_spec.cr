require "../spec_helper"

private def exact_time_read(cnn, expression)
  cnn.query("SELECT #{expression}, CAST(#{expression} AS VARCHAR), #{expression}") do |rs|
    rs.move_next
    value = rs.read
    value.to_s.should eq(rs.read(String))
    rs.read(String).should eq(value.to_s)
  end
end

describe "DuckDB exact temporal values" do
  it "formats dates over the full range like DuckDB, including small years and BC" do
    with_cnn do |cnn|
      %w(infinity -infinity 0001-01-01 0000-01-01 0010-02-03 10000-01-01).each do |text|
        exact_time_read(cnn, "DATE '#{text}'")
      end
      exact_time_read(cnn, "DATE '0044-03-15 (BC)'")
      [-Int32::MAX + 1, -719528, 0, Int32::MAX - 1].each do |days|
        date = DuckDB::Date.new(days)
        cnn.query("SELECT ?::DATE, CAST(?::DATE AS VARCHAR)", date, date) do |rs|
          rs.move_next
          rs.read(DuckDB::Date).to_s.should eq(rs.read(String))
        end
      end
      cnn.query("SELECT DATE '2020-01-02', NULL::DATE") do |rs|
        rs.move_next
        rs.read(Time).should eq(Time.utc(2020, 1, 2))
        rs.read(Time?).should be_nil
      end
      DuckDB::Date.new(Int32::MAX).infinite?.should be_true
      DuckDB::Date.new(-Int32::MAX).infinite?.should be_true
      DuckDB::Date.new(0).infinite?.should be_false
    end
  end

  it "preserves every timestamp resolution, timezone provenance and infinity" do
    with_cnn do |cnn|
      cnn.exec "SET TimeZone='UTC'"
      types = %w(TIMESTAMP TIMESTAMP_S TIMESTAMP_MS TIMESTAMP_NS TIMESTAMPTZ)
      types << "TIMESTAMPTZ_NS" if cnn.scalar("SELECT version()").as(String).starts_with?("v2.")
      types.each do |type|
        %w(infinity -infinity).each do |text|
          exact_time_read(cnn, "'#{text}'::#{type}")
          value = cnn.scalar("SELECT '#{text}'::#{type}").as(DuckDB::Timestamp)
          value.infinite?.should be_true
          expect_raises(DuckDB::Exception) { value.to_time }
        end
        expression = "'1969-12-31 23:59:59.123456789'::#{type}"
        exact_time_read(cnn, expression)
        cnn.query("SELECT #{expression}, #{expression}, NULL::#{type}") do |rs|
          rs.move_next
          value = rs.read(DuckDB::Timestamp)
          value.timezone?.should eq(type.starts_with?("TIMESTAMPTZ"))
          rs.read(Time).should eq(value.to_time)
          rs.read(Time?).should be_nil
        end
      end
      %w(1600-01-01 2300-01-01 9999-12-31 10000-01-01).each do |date|
        exact_time_read(cnn, "TIMESTAMP '#{date} 12:34:56.123456'")
      end
      exact_time_read(cnn, "TIMESTAMP '0001-01-02 (BC) 03:04:05.123456'")
    end
  end

  it "validates time fields and durations and reads 24:00:00 (F07)" do
    [{-1, 0, 0, 0}, {25, 0, 0, 0}, {24, 1, 0, 0}, {24, 0, 1, 0}, {24, 0, 0, 1}, {0, 60, 0, 0}, {0, -1, 0, 0}, {0, 0, 60, 0}, {0, 0, -1, 0}, {0, 0, 0, -1}, {0, 0, 0, 1_000_000}].each do |fields|
      expect_raises(ArgumentError) { DuckDB::TimeOfDay.new(*fields) }
    end
    [-1_i64, 86_400_000_001_i64].each { |v| expect_raises(ArgumentError) { DuckDB::TimeOfDay.new(v) } }
    expect_raises(ArgumentError) { DuckDB::TimeOfDay.new(-1.nanosecond) }
    expect_raises(ArgumentError) { DuckDB::TimeOfDay.new("24:00:00.000000001") }
    expect_raises(ArgumentError) { DuckDB::TimeOfDay.from_nanoseconds(-1_i64) }
    DuckDB::TimeOfDay.new(24, 0).to_s.should eq("24:00:00")
    with_cnn do |cnn|
      ["TIME '24:00:00'", "'24:00:00'::TIME_NS", "'12:34:56.123456789'::TIME_NS", "TIMETZ '24:00:00-05:30:01'", "TIMETZ '12:34:56.123456+00'"].each do |expression|
        exact_time_read(cnn, expression)
      end
    end
  end

  it "binds Date, TIME, TIME_NS, timestamps and Time without float conversion (F06)" do
    with_cnn do |cnn|
      [Time.utc(1600, 1, 1, 12, 34, 56, nanosecond: 123456000), Time.utc(2300, 1, 1, 12, 34, 56, nanosecond: 123456000), Time.utc(9999, 12, 31, 23, 59, 59, nanosecond: 999999000), Time.unix(-1) + 999_999_999.nanoseconds].each do |time|
        value = DuckDB::Timestamp.new(time)
        cnn.scalar("SELECT ?", value).should eq(value)
        cnn.scalar("SELECT ?", time).should eq(value)
        cnn.query("SELECT ?", time) { |rs| rs.move_next; rs.read(Time).should eq(time) }
      end
      [DuckDB::TimeOfDay.new(24, 0), DuckDB::TimeOfDay.new("12:34:56.123456789")].each do |v|
        cnn.scalar("SELECT ?", v).should eq(v)
      end
      tz = DuckDB::TimeTZ.new(DuckDB::TimeOfDay.new(24, 0), -19801)
      cnn.scalar("SELECT ?", tz).should eq(tz)
      cnn.scalar("SELECT ?", DuckDB::Timestamp.from_raw(1_i64, DuckDB::LibDuckDB::Type::TIMESTAMP_TZ)).as(DuckDB::Timestamp).timezone?.should be_true
      expect_raises(DuckDB::Exception) { cnn.scalar("SELECT ?", DuckDB::Timestamp.from_nanoseconds(Int128::MAX)) }
    end
  end

  it "holds the full raw range of every timestamp unit without overflow" do
    with_cnn do |cnn|
      [DuckDB::LibDuckDB::Type::TIMESTAMP_S, DuckDB::LibDuckDB::Type::TIMESTAMP_MS, DuckDB::LibDuckDB::Type::TIMESTAMP, DuckDB::LibDuckDB::Type::TIMESTAMP_NS].each do |type|
        [Int64::MAX - 1, -Int64::MAX + 1].each do |raw|
          value = DuckDB::Timestamp.from_raw(raw, type)
          value.infinite?.should be_false
          value.to_s.empty?.should be_false
          value.year.should be_a(Int64)
          value.month.should be >= 1
          value.month.should be <= 12
          cnn.scalar("SELECT ?::#{type}", value).should eq(value)
          expect_raises(DuckDB::Exception) { value.to_time } unless type.timestamp_ns?
        end
      end
    end
  end
end
