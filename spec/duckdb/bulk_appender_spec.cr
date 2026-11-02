require "../spec_helper"
require "../support/lifecycle"

# A native oracle: suppress direct writes, leaving all DuckDB conversions and
# native Begin/EndRow/Close operations in place. No destination data is invented.
private class NativeRowAppender < DuckDB::Appender
  private def append_direct(value) : Bool
    to_unsafe
    false
  end
end

native_lifetime do
  private def bulk_handles
    {NativeLifetime.values, NativeLifetime.logical_types, NativeLifetime.chunks, NativeLifetime.appenders}
  end
end

macro compare_append(sql_type, values)
  cnn.exec "CREATE OR REPLACE TABLE direct_values (v {{sql_type.id}})"
  cnn.exec "CREATE OR REPLACE TABLE native_values (v {{sql_type.id}})"
  chunks_before = native_lifetime { NativeLifetime.appended_chunks }
  cnn.appender("direct_values") do |a|
    {{values}}.each { |value| a.row { |r| r << value } }
    a.row { |r| r << nil }
  end
  native_lifetime { NativeLifetime.appended_chunks.should be > chunks_before }
  chunks_before = native_lifetime { NativeLifetime.appended_chunks }
  oracle = NativeRowAppender.new(cnn, "native_values")
  begin
    {{values}}.each { |value| oracle.row { |r| r << value } }
    oracle.row { |r| r << nil }
  ensure
    oracle.close
  end
  native_lifetime { NativeLifetime.appended_chunks.should eq(chunks_before) }
  cnn.exec "CREATE OR REPLACE TABLE column_values (v {{sql_type.id}})"
  cnn.appender("column_values") { |a| a.append_columns({{values}} + [nil]) }
  {% if sql_type.starts_with?("TIMESTAMP") %}
    cnn.query_all("SELECT v FROM direct_values", as: DuckDB::Timestamp?).should eq(cnn.query_all("SELECT v FROM native_values", as: DuckDB::Timestamp?))
    cnn.query_all("SELECT v FROM column_values", as: DuckDB::Timestamp?).should eq(cnn.query_all("SELECT v FROM native_values", as: DuckDB::Timestamp?))
  {% else %}
    cnn.query_all("SELECT v::VARCHAR FROM direct_values", as: String?).should eq(cnn.query_all("SELECT v::VARCHAR FROM native_values", as: String?))
    cnn.query_all("SELECT v::VARCHAR FROM column_values", as: String?).should eq(cnn.query_all("SELECT v::VARCHAR FROM native_values", as: String?))
  {% end %}
end

describe "DuckDB chunk-buffered appending" do
  {% for source_info in { {Int8, 8, true}, {Int16, 16, true}, {Int32, 32, true}, {Int64, 64, true}, {Int128, 128, true}, {UInt8, 8, false}, {UInt16, 16, false}, {UInt32, 32, false}, {UInt64, 64, false}, {UInt128, 128, false} } %}
  {% source = source_info[0] %}
  {% bits = source_info[1] %}
  {% signed = source_info[2] %}
    {% for target_info in { {:TINYINT, 8, true}, {:SMALLINT, 16, true}, {:INTEGER, 32, true}, {:BIGINT, 64, true}, {:HUGEINT, 128, true}, {:UTINYINT, 8, false}, {:USMALLINT, 16, false}, {:UINTEGER, 32, false}, {:UBIGINT, 64, false}, {:UHUGEINT, 128, false} } %}
    {% target = target_info[0] %}
    {% size = target_info[1] %}
    {% sign = target_info[2] %}
      {% if (signed == sign && size >= bits) || (!signed && sign && size > bits) %}
        it "writes {{source}} extrema directly into {{target.id}} exactly like native appends" do
          with_cnn do |cnn|
            compare_append {{target.id.stringify}}, [{{source}}::MIN, {{source}}.new(0), {{source}}::MAX]
          end
        end
      {% end %}
    {% end %}
  {% end %}

  it "writes exact scalar layouts and decimal rescaling exactly like native appends" do
    with_cnn do |cnn|
      before = native_lifetime { bulk_handles }
      compare_append "BOOLEAN", [false, true]
      compare_append "FLOAT", [-0.0_f32, Float32::MIN_POSITIVE, Float32::MAX, Float32::INFINITY, -Float32::INFINITY]
      compare_append "DOUBLE", [-0.0, Float64::MIN_POSITIVE, Float64::MAX, Float64::INFINITY, -Float64::INFINITY]
      compare_append "VARCHAR", ["", "a\0b", "ü" * 50, "x" * 12, "x" * 13]
      compare_append "BLOB", [Bytes.empty, Bytes[0, 255, 128], ("x" * 100).to_slice]
      compare_append "UUID", [UUID.new("00000000-0000-0000-0000-000000000000"), UUID.new("7fffffff-ffff-ffff-ffff-ffffffffffff"), UUID.new("80000000-0000-0000-0000-000000000000"), UUID.new("ffffffff-ffff-ffff-ffff-ffffffffffff")]
      compare_append "DATE", [DuckDB::Date.new("infinity"), DuckDB::Date.new("-infinity"), DuckDB::Date.new(-719528), DuckDB::Date.new(0)]
      compare_append "INTERVAL", [DuckDB::Interval.new(Int64::MIN, Int32::MAX, Int32::MIN), DuckDB::Interval.new(123, -3, 5)]
      {% for width in [4, 9, 18, 38] %}
        {% for scale in [0, 2, width] %}
          compare_append {{"DECIMAL(#{width},#{scale})"}}, [DuckDB::Decimal.new(-(10_i128 ** {{width}}) + 1, {{width}}, {{scale}}), DuckDB::Decimal.new(0_i128, {{width}}, {{scale}}), DuckDB::Decimal.new(10_i128 ** {{width}} - 1, {{width}}, {{scale}})]
        {% end %}
      {% end %}
      compare_append "DECIMAL(18,3)", [DuckDB::Decimal.new(-12300_i128, 9, 4), DuckDB::Decimal.new(123_i128, 4, 1)]
      compare_append "TIME", [DuckDB::TimeOfDay.new(0_i64), DuckDB::TimeOfDay.new(24, 0)]
      compare_append "TIME_NS", [DuckDB::TimeOfDay.from_nanoseconds(1_i64), DuckDB::TimeOfDay.new(24, 0)]
      {% for kind in %w(TIMESTAMP TIMESTAMP_S TIMESTAMP_MS TIMESTAMP_NS TIMESTAMP_TZ) %}
        compare_append {{kind == "TIMESTAMP_TZ" ? "TIMESTAMPTZ" : kind}}, [DuckDB::Timestamp.from_raw(1_i64, DuckDB::Type::{{kind.id}}), DuckDB::Timestamp.from_raw(-Int64::MAX + 1, DuckDB::Type::{{kind.id}}), DuckDB::Timestamp.from_raw(Int64::MAX - 1, DuckDB::Type::{{kind.id}}), DuckDB::Timestamp.from_raw(Int64::MAX, DuckDB::Type::{{kind.id}}), DuckDB::Timestamp.from_raw(-Int64::MAX, DuckDB::Type::{{kind.id}})]
      {% end %}
      native_lifetime { bulk_handles.should eq(before) }
    end
  end

  it "preserves native floating NaN and signed-zero bits" do
    with_cnn do |cnn|
      cnn.exec "CREATE TABLE floats (f FLOAT, d DOUBLE)"
      cnn.appender("floats") do |a|
        a.row { |r| r << -0.0_f32 << -0.0 }
        a.row { |r| r << Float32::NAN << Float64::NAN }
      end
      cnn.query("SELECT f,d FROM floats") do |rs|
        rs.move_next
        rs.read(Float32).unsafe_as(UInt32).should eq(0x80000000_u32)
        rs.read(Float64).unsafe_as(UInt64).should eq(0x8000000000000000_u64)
        rs.move_next
        rs.read(Float32).nan?.should be_true
        rs.read(Float64).nan?.should be_true
      end
    end
  end

  it "preserves order through direct/native row prefixes, native boundaries, and explicit flush" do
    with_cnn do |cnn|
      cnn.exec "CREATE TYPE color AS ENUM ('red','blue')"
      cnn.exec "CREATE TABLE mixed (n BIGINT, d DECIMAL(18,3), label VARCHAR, b BLOB, tail BIGINT)"
      expected = [] of Int64
      cnn.appender("mixed") do |a|
        7000.times do |i|
          a.row do |r|
            # A string-to-number fallback at either end of a row, in long runs
            # and on either side of a vector boundary, exercises prefix replay.
            if i % 17 == 0 || (2046..2049).includes?(i)
              r << i.to_s
            else
              r << i
            end
            r << DuckDB::Decimal.new(i.to_i128, 18, 3) << (i.even? ? "short\0text" : "ü" * 40) << Bytes[0, 255]
            i % 19 == 0 ? r << i.to_s : r << i
          end
          expected << i.to_i64
          a.flush if i == 3017
        end
      end
      cnn.query_all("SELECT n FROM mixed", as: Int64).should eq(expected)
      cnn.query_all("SELECT tail FROM mixed", as: Int64).should eq(expected)
      cnn.query_all("SELECT d FROM mixed", as: DuckDB::Decimal).map(&.value).should eq(expected.map(&.to_i128))
      cnn.query_all("SELECT b FROM mixed", as: Bytes).should eq([Bytes[0, 255]] * expected.size)
      cnn.appender("mixed") { |a| a.row { |r| r << 7000 << nil << nil << nil << "7000" } }
      cnn.exec "CREATE TABLE enums (n BIGINT, c color)"
      cnn.appender("enums") { |a| 5000.times { |i| a.row { |r| r << i << (i.even? ? "red" : "blue") } } }
      cnn.query_all("SELECT n FROM enums", as: Int64).should eq((0...5000).map(&.to_i64))
    end
  end

  it "raises conversion failures at the supplying <<, permits retry, and retains the partial row" do
    with_cnn do |cnn|
      cnn.exec "CREATE TABLE numbers (a BIGINT, b TINYINT)"
      a = cnn.appender("numbers")
      begin
        a.row { |r| r << 1 << 2_i8 }
        a << 3
        expect_raises(DuckDB::Exception, /Failed to append value.*convert/) { a << "bad" }
        expect_raises(DuckDB::Exception, /Failed to append value/) { a << 1000 }
        a << 4_i8
        a.end_row
        a.row { |r| r << 5 << 6_i8 }
      ensure
        a.close
      end
      cnn.query_all("SELECT a,b FROM numbers", as: {Int64, Int8}).should eq([{1_i64, 2_i8}, {3_i64, 4_i8}, {5_i64, 6_i8}])
    end
  end

  it "keeps short and overfull rows as errors, with native recovery and close behavior" do
    with_cnn do |cnn|
      cnn.exec "CREATE TABLE numbers (a BIGINT, b BIGINT)"
      a = cnn.appender("numbers")
      a.row { |r| r << 1 << 2 }
      a << 3
      a.begin_row # Must not reset the partial row.
      expect_raises(DuckDB::Exception, /EndRow before all columns/) { a.end_row }
      a << 4
      a.end_row
      a.close
      cnn.scalar("SELECT count(*) FROM numbers").should eq(2)
      cnn.exec "DELETE FROM numbers"
      a = cnn.appender("numbers")
      a.row { |r| r << 1 << 2 }
      a << 3 << 4
      expect_raises(DuckDB::Exception, /Too many appends/) { a << 5 }
      expect_raises(DuckDB::Exception, /close/) { a.close }
      a.closed?.should be_true
      a.close
      cnn.scalar("SELECT count(*) FROM numbers").should eq(0)
    end
  end

  {% for exit in %w(flush partial_close full_close block_raise block_return block_partial_raise conversion_error) %}
    it "preserves native persistence/discard for {{exit.id}} with complete chunks already buffered" do
      with_cnn do |cnn|
        cnn.exec "CREATE TABLE numbers (a BIGINT, b BIGINT)"
        before = native_lifetime { bulk_handles }
        a = cnn.appender("numbers")
        5000.times { |i| a.row { |r| r << i << i } }
        {% if exit == "flush" %}
          a.flush
          cnn.scalar("SELECT count(*) FROM numbers").should eq(5000)
          a.close
        {% elsif exit == "partial_close" %}
          a << 1
          a.close # Native Close quietly discards all pending rows.
        {% elsif exit == "full_close" %}
          a << 1 << 2
          expect_raises(DuckDB::Exception, /close/) { a.close }
        {% elsif exit == "conversion_error" %}
          a << 1
          expect_raises(DuckDB::Exception, /Failed to append/) { a << "bad" }
          a.close
        {% else %}
          a.close
          cnn.exec "DELETE FROM numbers"
          {% if exit == "block_return" %}
            cnn.appender("numbers") { |b| 5000.times { |i| b.row { |r| r << i << i } } }
          {% else %}
            expect_raises(Exception, /user failure/) do
              cnn.appender("numbers") do |b|
                5000.times { |i| b.row { |r| r << i << i } }
                {% if exit == "block_partial_raise" %} b << 1 {% end %}
                raise "user failure"
              end
            end
          {% end %}
        {% end %}
        cnn.scalar("SELECT count(*) FROM numbers").should eq({{["flush", "block_raise", "block_return"].includes?(exit) ? 5000 : 0}})
        native_lifetime { bulk_handles.should eq(before) }
      end
    end
  {% end %}

  it "keeps completed rows after an error at the first column, and after an incomplete flush discards pending data" do
    with_cnn do |cnn|
      cnn.exec "CREATE TABLE numbers (a BIGINT, b BIGINT)"
      a = cnn.appender("numbers")
      3000.times { |i| a.row { |r| r << i << i } }
      expect_raises(DuckDB::Exception) { a << "bad" }
      a.close
      cnn.scalar("SELECT count(*) FROM numbers").should eq(3000)
      cnn.exec "DELETE FROM numbers"
      a = cnn.appender("numbers")
      3000.times { |i| a.row { |r| r << i << i } }
      a << 1
      expect_raises(DuckDB::Exception, /incomplete append to row/) { a.flush }
      a.close
      cnn.scalar("SELECT count(*) FROM numbers").should eq(0)
    end
  end

  it "keeps invalid UTF-8 on the native error path, never silently storing NULL" do
    with_cnn do |cnn|
      [Bytes[255], Bytes[0xc0, 0x80], Bytes[0xed, 0xa0, 0x80], Bytes[0xe2, 0x82]].each do |bytes|
        cnn.exec "CREATE OR REPLACE TABLE texts (v VARCHAR)"
        before = native_lifetime { bulk_handles }
        a = cnn.appender("texts")
        a.row { |r| r << "valid" }
        a << String.new(bytes) # Both native versions accept this call.
        a.end_row
        expect_raises(DuckDB::Exception, /close/) { a.close }
        cnn.scalar("SELECT count(*) FROM texts").should eq(0)
        native_lifetime { bulk_handles.should eq(before) }
      end
    end
  end

  native_lifetime_it "destroys chunks/types after creation failure, constraint errors, and every closed operation" do
    with_cnn do |cnn|
      cnn.exec "CREATE TABLE numbers (v BIGINT NOT NULL UNIQUE)"
      before = bulk_handles
      NativeLifetime.fail_create_chunk_after(0)
      expect_raises(DuckDB::Exception, /create appender data chunk/) { cnn.appender("numbers") }
      NativeLifetime.fail_create_chunk_after(-1)
      bulk_handles.should eq(before)
      expect_raises(DuckDB::Exception) { cnn.appender("missing_table") }
      bulk_handles.should eq(before)
      a = cnn.appender("numbers")
      a.row { |r| r << 1 }
      a.row { |r| r << 1 }
      expect_raises(DuckDB::Exception) { a.close }
      a.closed?.should be_true
      bulk_handles.should eq(before)
      expect_raises(DuckDB::Exception, /closed/) { a << 1 }
      expect_raises(DuckDB::Exception, /closed/) { a << nil }
      expect_raises(DuckDB::Exception, /closed/) { a.begin_row }
      expect_raises(DuckDB::Exception, /closed/) { a.end_row }
      expect_raises(DuckDB::Exception, /closed/) { a.flush }
      expect_raises(DuckDB::Exception, /closed/) { a.append_columns([1]) }
      a.close
    end
  end

  it "flushes a connection's open appenders before disconnect, including mixed successful/failing cleanup" do
    before = native_lifetime { bulk_handles }
    path = File.join(__DIR__, "../../.tmp/bulk-close.db")
    File.delete?(path)
    cnn = DB.connect("duckdb://#{path}").as(DuckDB::Connection)
    cnn.exec "CREATE TABLE numbers (v BIGINT);"
    cnn.exec "CREATE TABLE invalid (v BIGINT NOT NULL);"
    good = cnn.appender("numbers")
    5000.times { |i| good.row { |r| r << i } }
    bad = cnn.appender("invalid")
    bad.row { |r| r << nil }
    expect_raises(DuckDB::Exception) { cnn.close }
    good.closed?.should be_true
    bad.closed?.should be_true
    native_lifetime { bulk_handles.should eq(before) }
    DB.connect("duckdb://#{path}") { |c| c.scalar("SELECT count(*) FROM numbers").should eq(5000) }
  ensure
    cnn.try &.close
    File.delete?(path) if path
  end
end

describe "DuckDB columnar appending" do
  it "loads nullable Indexables over chunk boundaries, interleaved with rows, casts and flushes" do
    with_cnn do |cnn|
      cnn.exec "CREATE TABLE columns (n BIGINT, s VARCHAR, d DECIMAL(18,3), t TIMESTAMP, b BLOB)"
      before = native_lifetime { bulk_handles }
      n = Array(Int32?).new(5000) { |i| i % 7 == 0 ? nil : i }
      s = Array(String?).new(5000) { |i| i % 7 == 0 ? nil : "v\0#{i}" }
      d = Array(DuckDB::Decimal?).new(5000) { |i| i % 7 == 0 ? nil : DuckDB::Decimal.new(i.to_i128, 18, 3) }
      t = Array(DuckDB::Timestamp?).new(5000) { |i| i % 7 == 0 ? nil : DuckDB::Timestamp.new(i.to_i64) }
      b = Array(Bytes?).new(5000) { |i| i % 7 == 0 ? nil : Bytes[255, 0] }
      cnn.appender("columns") do |a|
        a.row { |r| r << "-1" << nil << nil << nil << nil }
        a.append_columns(n, s, d, t, b)
        a.flush
        a.append_columns(Slice.new(n.to_unsafe, n.size), s, d, t, b)
        a.row { |r| r << 5000 << "tail" << nil << nil << nil }
      end
      cnn.query_all("SELECT n FROM columns", as: Int64?).should eq([-1_i64] + n + n + [5000_i64])
      cnn.query_all("SELECT s FROM columns", as: String?).should eq([nil] + s + s + ["tail"])
      cnn.query_all("SELECT d FROM columns", as: DuckDB::Decimal?).should eq([nil] + d + d + [nil])
      native_lifetime { bulk_handles.should eq(before) }
    end
  end

  it "checks counts, lengths and all union element types before appending" do
    with_cnn do |cnn|
      cnn.exec "CREATE TABLE columns (n BIGINT, s VARCHAR)"
      cnn.appender("columns") do |a|
        expect_raises(DuckDB::Exception, /Expected 2 columns/) { a.append_columns([1]) }
        expect_raises(DuckDB::Exception, /lengths/) { a.append_columns([1, 2], ["one"]) }
        expect_raises(DuckDB::Exception, /element type/) { a.append_columns([1], [2]) }
        expect_raises(DuckDB::Exception, /element type/) { a.append_columns([1, "bad"], ["one", "two"]) }
        a.append_columns([] of Int32, [] of String)
        a.append_columns([1], ["one"])
        a << 2
        expect_raises(DuckDB::Exception, /row boundary/) { a.append_columns([3], ["three"]) }
        a << "two"
        a.end_row
      end
      cnn.query_all("SELECT n FROM columns", as: Int64).should eq([1, 2])
    end
  end

  it "discards a bad input chunk, preserves earlier chunks, and permits a corrected retry including validity masks" do
    with_cnn do |cnn|
      cnn.exec "CREATE TABLE columns (n BIGINT, s VARCHAR, d DECIMAL(4,1))"
      cnn.appender("columns") do |a|
        a.row { |r| r << -1 << "prefix" << DuckDB::Decimal.new(1_i128, 4, 1) }
        expect_raises(DuckDB::Exception, /cannot be appended exactly/) { a.append_columns([1, 2], [nil, String.new(Bytes[255])], [DuckDB::Decimal.new(1_i128, 4, 1)] * 2) }
        expect_raises(DuckDB::Exception, /cannot be appended exactly/) { a.append_columns([1, 2], ["one", "two"], [DuckDB::Decimal.new(1_i128, 4, 1), DuckDB::Decimal.new(123_i128, 4, 2)]) }
        a.append_columns([1, 2], ["one", "two"], [DuckDB::Decimal.new(1_i128, 4, 1)] * 2)
      end
      cnn.query_all("SELECT n FROM columns", as: Int64).should eq([-1, 1, 2])
      cnn.query_all("SELECT s FROM columns", as: String).should eq(["prefix", "one", "two"])
    end
  end

  it "writes submicrosecond timezone-provenance timestamps on 2.0 without a value constructor, including prefix replay" do
    with_cnn do |cnn|
      next unless cnn.scalar("SELECT version()").as(String).starts_with?("v2.")
      cnn.exec "SET TimeZone='America/Denver'"
      cnn.exec "CREATE TABLE times (t TIMESTAMPTZ_NS, n BIGINT)"
      values = [-1_i64, 1_i64, Int64::MAX - 1, -Int64::MAX + 1, Int64::MAX, -Int64::MAX].map { |raw| DuckDB::Timestamp.from_raw(raw, DuckDB::Type::TIMESTAMP_TZ_NS) }
      cnn.appender("times") do |a|
        values.each { |v| a.row { |r| r << v << 1 } }
        # Native conversion after a TZ_NS prefix must not need a 2.0 symbol.
        values.each { |v| a.row { |r| r << v << "2" } }
        a.append_columns(values, [3] * values.size)
      end
      cnn.query_all("SELECT t FROM times", as: DuckDB::Timestamp).should eq(values * 3)
      cnn.exec "CREATE TABLE micros (t TIMESTAMPTZ)"
      expect_raises(DuckDB::Exception, /lose precision/) { cnn.appender("micros") { |a| a << values[0] } }
    end
  end
end

describe "DuckDB fallback conversion equivalence" do
  it "retains cross-type, narrowing, enum, decimal and temporal conversion results" do
    with_cnn do |cnn|
      # These require native conversions. Direct writes must not replace their
      # rounding, timezone, range checks, or supported/unsupported cast rules.
      {
        "TINYINT"            => [1_i64, -2_i32, 3_u64],
        "BIGINT"             => ["1", 2.5_f64, 3_u64],
        "FLOAT"              => [1_f64, 2_i32],
        "DOUBLE"             => [1_f32, 2_i64],
        "VARCHAR"            => [1_i32, true, DuckDB::Decimal.new(123_i128, 4, 2)],
        "DECIMAL(18,3)"      => [1_i32, "1.2345"],
        "ENUM('red','blue')" => ["red", "blue"],
        "BIT"                => ["0", "101"],
        "TIME"               => ["12:34:56.123456"],
        "TIMESTAMPTZ"        => [DuckDB::Timestamp.new(Time.utc(2026, 1, 1))],
        "TIMESTAMP"          => [DuckDB::Timestamp.from_raw(123_i64, DuckDB::Type::TIMESTAMP_TZ)],
      }.each do |sql_type, values|
        cnn.exec "SET TimeZone='America/Denver'"
        cnn.exec "CREATE OR REPLACE TABLE direct_values (v #{sql_type})"
        cnn.exec "CREATE OR REPLACE TABLE native_values (v #{sql_type})"
        cnn.appender("direct_values") { |a| values.each { |value| a.row { |r| r << value } } }
        a = NativeRowAppender.new(cnn, "native_values")
        values.each { |value| a.row { |r| r << value } }
        a.close
        cnn.query_all("SELECT v::VARCHAR FROM direct_values", as: String?).should eq(cnn.query_all("SELECT v::VARCHAR FROM native_values", as: String?))
      end
    end
  end

  it "raises decimal overflow from << without overflowing the host rescale calculation" do
    with_cnn do |cnn|
      cnn.exec "CREATE TABLE decimals (v DECIMAL(38,38))"
      a = cnn.appender("decimals")
      expect_raises(DuckDB::Exception, /Failed to append/) { a << DuckDB::Decimal.new(10_i128 ** 38 - 1, 38, 0) }
      a << DuckDB::Decimal.new(1_i128, 38, 38)
      a.end_row
      a.close
      cnn.scalar("SELECT v FROM decimals").should eq(DuckDB::Decimal.new(1_i128, 38, 38))
    end
  end
end

describe "DuckDB buffered append discard boundaries" do
  it "leaves completed chunks buffered until flush and retains transaction rollback" do
    with_cnn do |cnn|
      cnn.exec "CREATE TABLE numbers (v BIGINT)"
      a = cnn.appender("numbers")
      5000.times { |i| a.row { |r| r << i } }
      cnn.scalar("SELECT count(*) FROM numbers").should eq(0)
      a.flush
      cnn.scalar("SELECT count(*) FROM numbers").should eq(5000)
      a.close
      cnn.exec "DELETE FROM numbers"
      cnn.exec "BEGIN TRANSACTION"
      cnn.appender("numbers") { |b| b.append_columns((0...5000).to_a) }
      cnn.scalar("SELECT count(*) FROM numbers").should eq(5000)
      cnn.exec "ROLLBACK"
      cnn.scalar("SELECT count(*) FROM numbers").should eq(0)
    end
  end

  it "preserves the native UTF-8 flush error and cleanup after flush failure" do
    with_cnn do |cnn|
      cnn.exec "CREATE TABLE texts (v VARCHAR)"
      before = native_lifetime { bulk_handles }
      a = cnn.appender("texts")
      a.row { |r| r << "valid" }
      a.row { |r| r << String.new(Bytes[255]) }
      expect_raises(DuckDB::Exception, /Invalid unicode/) { a.flush }
      if cnn.scalar("SELECT version()").as(String).starts_with?("v1.")
        expect_raises(DuckDB::Exception, /close/) { a.close }
      else
        a.close
      end
      cnn.scalar("SELECT count(*) FROM texts").should eq(0)
      native_lifetime { bulk_handles.should eq(before) }
    end
  end
end

describe "DuckDB exact row prefix replay" do
  it "replays every direct physical layout before a fallback without changing stored values" do
    with_cnn do |cnn|
      schema = "h HUGEINT, u UHUGEINT, b BOOLEAN, f FLOAT, d DOUBLE, d4 DECIMAL(4,2), d9 DECIMAL(9,2), d18 DECIMAL(18,3), d38 DECIMAL(38,10), id UUID, dt DATE, iv INTERVAL, tm TIME_NS, ts TIMESTAMP_S, ms TIMESTAMP_MS, ns TIMESTAMP_NS, tz TIMESTAMPTZ, label VARCHAR, blob BLOB, n BIGINT"
      cnn.exec "CREATE TABLE direct_values (#{schema})"
      cnn.exec "CREATE TABLE native_values (#{schema})"
      [cnn.appender("direct_values"), NativeRowAppender.new(cnn, "native_values")].each do |a|
        begin
          2100.times do |i|
            a.row do |r|
              r << Int128::MIN << UInt128::MAX << true << -0.0_f32 << Float64::INFINITY
              r << DuckDB::Decimal.new(-1234_i128, 4, 2) << DuckDB::Decimal.new(123456789_i128, 9, 2)
              r << DuckDB::Decimal.new(-123456789123456789_i128, 18, 3) << DuckDB::Decimal.new(10_i128 ** 38 - 1, 38, 10)
              r << UUID.new("80000000-0000-0000-0000-000000000001") << DuckDB::Date.new("infinity") << DuckDB::Interval.new(123_i64, -5, 8)
              r << DuckDB::TimeOfDay.from_nanoseconds(1_i64)
              r << DuckDB::Timestamp.from_raw(1_i64, DuckDB::Type::TIMESTAMP_S) << DuckDB::Timestamp.from_raw(1_i64, DuckDB::Type::TIMESTAMP_MS)
              r << DuckDB::Timestamp.from_raw(1_i64, DuckDB::Type::TIMESTAMP_NS) << DuckDB::Timestamp.from_raw(1_i64, DuckDB::Type::TIMESTAMP_TZ)
              r << "ü\0long-label" * 5 << Bytes[0, 255, 128] << i.to_s
            end
          end
        ensure
          a.close
        end
      end
      cnn.scalar("SELECT count(*) FROM ((SELECT * FROM direct_values) EXCEPT ALL (SELECT * FROM native_values))").should eq(0)
      cnn.query_all("SELECT n FROM direct_values", as: Int64).should eq((0...2100).map(&.to_i64))
    end
  end

  it "matches native NaN payloads and zero signs in both float widths" do
    with_cnn do |cnn|
      cnn.exec "CREATE TABLE direct_values (f FLOAT, d DOUBLE)"
      cnn.exec "CREATE TABLE native_values (f FLOAT, d DOUBLE)"
      floats = [0_u32, 0x80000000_u32, 0x7fc12345_u32, 0xffc12345_u32, 0x7fa12345_u32].map(&.unsafe_as(Float32))
      doubles = [0_u64, 0x8000000000000000_u64, 0x7ff8123456789abc_u64, 0xfff8123456789abc_u64, 0x7ff4123456789abc_u64].map(&.unsafe_as(Float64))
      [cnn.appender("direct_values"), NativeRowAppender.new(cnn, "native_values")].each do |a|
        begin
          floats.each_with_index { |value, i| a.row { |r| r << value << doubles[i] } }
        ensure
          a.close
        end
      end
      actual = cnn.query_all("SELECT f,d FROM direct_values", as: {Float32, Float64}).map { |v| {v[0].unsafe_as(UInt32), v[1].unsafe_as(UInt64)} }
      expected = cnn.query_all("SELECT f,d FROM native_values", as: {Float32, Float64}).map { |v| {v[0].unsafe_as(UInt32), v[1].unsafe_as(UInt64)} }
      actual.should eq(expected)
    end
  end
end

describe "DuckDB automatic append flush boundaries" do
  it "preserves the native automatic flush boundary when a later partial row is discarded" do
    with_cnn do |cnn|
      [204799, 204800, 206000].each do |count|
        cnn.exec "CREATE OR REPLACE TABLE direct_values (n BIGINT, v BIGINT)"
        cnn.exec "CREATE OR REPLACE TABLE native_values (n BIGINT, v BIGINT)"
        [cnn.appender("direct_values"), NativeRowAppender.new(cnn, "native_values")].each do |a|
          begin
            count.times do |i|
              a.row do |r|
                r << i
                i == 17 ? r << i.to_s : r << i
              end
            end
            a << -1
          ensure
            a.close
          end
        end
        expected = count < 204800 ? 0 : 204800
        cnn.scalar("SELECT count(*) FROM native_values").should eq(expected)
        cnn.scalar("SELECT count(*) FROM direct_values").should eq(expected)
        cnn.scalar("SELECT count(*) FROM ((SELECT * FROM direct_values) EXCEPT ALL (SELECT * FROM native_values))").should eq(0)
      end
    end
  end
end

describe "DuckDB NULL append layouts" do
  it "writes whole NULL nested/enum and geometry values directly and replays them safely" do
    with_cnn do |cnn|
      cnn.exec "CREATE TABLE nulls (l INTEGER[], s STRUCT(x INTEGER), m MAP(VARCHAR,INTEGER), a INTEGER[2], e ENUM('x'), u UNION(x INTEGER,y VARCHAR), g GEOMETRY, n BIGINT)"
      cnn.appender("nulls") do |a|
        2100.times do |i|
          a.row { |r| r << nil << nil << nil << nil << nil << nil << nil << (i.odd? ? i.to_s : i) }
        end
      end
      cnn.scalar("SELECT count(*) FROM nulls WHERE l IS NULL AND s IS NULL AND m IS NULL AND a IS NULL AND e IS NULL AND u IS NULL AND g IS NULL").should eq(2100)
      cnn.query_all("SELECT n FROM nulls", as: Int64).should eq((0...2100).map(&.to_i64))
    end
  end
end

describe "DuckDB columnar input chunk errors" do
  it "keeps earlier input chunks and discards the whole failing input chunk" do
    with_cnn do |cnn|
      cnn.exec "CREATE TABLE columns (n BIGINT, d DECIMAL(4,1))"
      values = Array.new(5000) { DuckDB::Decimal.new(1_i128, 4, 1) }
      values[-1] = DuckDB::Decimal.new(123_i128, 4, 2)
      cnn.appender("columns") do |a|
        expect_raises(DuckDB::Exception, /row 4999 cannot be appended exactly/) { a.append_columns((0...5000).to_a, values) }
      end
      cnn.query_all("SELECT n FROM columns", as: Int64).should eq((0...4096).map(&.to_i64))
    end
  end
end

describe "DuckDB automatic flush failures" do
  {% for native_prefix in [false, true] %}
    it "never resubmits the valid tail after an automatic constraint failure (native prefix: {{native_prefix}})" do
      with_cnn do |cnn|
        cnn.exec "CREATE TABLE numbers (n BIGINT NOT NULL, v BIGINT)"
        before = native_lifetime { bulk_handles }
        a = cnn.appender("numbers")
        expect_raises(DuckDB::Exception) do
          204800.times do |i|
            a.row do |r|
              i == 0 ? r << nil : r << i
              {% if native_prefix %}
                i == 17 ? r << i.to_s : r << i
              {% else %}
                r << i
              {% end %}
            end
          end
        end
        if cnn.scalar("SELECT version()").as(String).starts_with?("v1.")
          expect_raises(DuckDB::Exception) { a.close }
        else
          a.close
        end
        cnn.scalar("SELECT count(*) FROM numbers").should eq(0)
        native_lifetime { bulk_handles.should eq(before) }
      end
    end
  {% end %}
end
