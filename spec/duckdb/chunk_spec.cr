require "../spec_helper"
require "../support/lifecycle"

private def native_reader_handles
  {NativeLifetime.results, NativeLifetime.statements, NativeLifetime.chunks, NativeLifetime.logical_types}
end

# A boundary test without scanning two billion rows.
class DuckDB::ResultSet
  def spec_rows_read=(value : Int64)
    @rows_read = value
  end

  def spec_rows_read
    @rows_read
  end

  def spec_chunk_row
    @row_index
  end
end

describe "DuckDB chunk reader" do
  it "reads validity bits and skips columns across many chunks with one type tree" do
    DB.connect "duckdb::memory:?prepared_statements_cache=false" do |cnn|
      before = native_reader_handles
      types_before = NativeLifetime.acquired_types
      chunks_before = NativeLifetime.fetched_chunks
      cnn.query "SELECT i, CASE WHEN i % 65 = 0 THEN NULL ELSE i END AS nullable, 'tail' FROM range(10000) t(i)" do |rs|
        rs.column_names.should eq(["i", "nullable", "'tail'"])
        rows = 0_i64
        rs.each do
          rs.next_column_index.should eq(0)
          rs.read(Int64).should eq(rows)
          rs.read(Int64?).should eq(rows % 65 == 0 ? nil : rows)
          rs.next_column_index.should eq(2)
          NativeLifetime.chunks.should eq(before[2] + 1)
          rows += 1
        end
        rows.should eq(10000)
        2.times { rs.move_next.should be_false }
        NativeLifetime.chunks.should eq(before[2])
        (NativeLifetime.acquired_types - types_before).should eq(3)
      end
      (NativeLifetime.fetched_chunks - chunks_before).should be > 1
      native_reader_handles.should eq(before)
    end
  end

  it "copies strings and blobs before early close, including empty, NUL and long values" do
    DB.connect "duckdb::memory:?prepared_statements_cache=false" do |cnn|
      before = native_reader_handles
      rs = cnn.query("SELECT repeat('ü', 100), encode('a' || chr(0) || 'b'), '', ''::BLOB")
      rs.move_next.should be_true
      text = rs.read(String)
      bytes = rs.read(Bytes)
      rs.read(String).should eq("")
      rs.read(Bytes).should eq(Bytes.empty)
      rs.close
      rs.close
      text.should eq("ü" * 100)
      bytes.should eq(Bytes[97, 0, 98])
      native_reader_handles.should eq(before)
    end
  end

  it "fetches DDL, changed-row and empty query results through chunks" do
    with_cnn do |cnn|
      cnn.query("CREATE TABLE chunk_kinds (i INTEGER)") { |rs| rs.each { rs.read.should be_nil } }
      cnn.query("INSERT INTO chunk_kinds VALUES (42), (43)") do |rs|
        rs.move_next.should be_true
        rs.read(Int64).should eq(2)
        rs.move_next.should be_false
      end
      cnn.query("SELECT * FROM chunk_kinds WHERE false") do |rs|
        rs.column_count.should eq(1)
        rs.move_next.should be_false
      end
    end
  end

  it "releases all handles when a result or its connection closes early" do
    before = native_reader_handles
    cnn = DB.connect("duckdb::memory:?prepared_statements_cache=false")
    rs = cnn.query("SELECT i, repeat('x', 100) FROM range(10000) t(i)")
    rs.move_next.should be_true
    cnn.close
    rs.closed?.should be_true
    native_reader_handles.should eq(before)
  ensure
    rs.try &.close
    cnn.try &.close
  end

  it "raises safely for closed results and reads outside a row" do
    with_cnn do |cnn|
      rs = cnn.query("SELECT 42")
      rs.close
      expect_raises(DuckDB::Exception, /closed/) { rs.read }
      expect_raises(DuckDB::Exception, /closed/) { rs.read(Int32) }
      expect_raises(DuckDB::Exception, /closed/) { rs.move_next }
      expect_raises(DuckDB::Exception, /closed/) { rs.column_count }
      expect_raises(DuckDB::Exception, /closed/) { rs.column_name(0) }
      expect_raises(DuckDB::Exception, /closed/) { rs.next_column_index }
      expect_raises(DuckDB::Exception, /positioned/) { cnn.query("SELECT 42") { |r| r.read } }
      expect_raises(DuckDB::Exception, /No more columns/) do
        cnn.query("SELECT 42") { |r| r.move_next; r.read; r.read }
      end
    end
  end

  it "rejects unsupported types with the type and column name and frees the tree" do
    DB.connect "duckdb::memory:?prepared_statements_cache=false" do |cnn|
      before = native_reader_handles
      {
        "VARIANT" => "42::VARIANT",
      }.each do |type, sql|
        expect_raises(DuckDB::Exception, /#{type}.*named_column/) do
          cnn.query("SELECT #{sql} AS named_column") { |rs| rs.move_next; rs.read }
        end
        native_reader_handles.should eq(before)
      end
    end
  end

  it "keeps row counters Int64 while the row index stays local to a chunk" do
    with_cnn do |cnn|
      cnn.query("SELECT i FROM range(5000) t(i)") do |result|
        rs = result.as(DuckDB::ResultSet)
        rs.spec_rows_read = Int32::MAX.to_i64 - 1
        5000.times do |i|
          rs.move_next.should be_true
          rs.read(Int64).should eq(i)
          rs.spec_chunk_row.should be_a(Int64)
          rs.spec_chunk_row.should be < 2048
        end
        rs.spec_rows_read.should eq(Int32::MAX.to_i64 + 4999)
      end
    end
  end

  it "reads integer extrema and typed nullable timestamps" do
    with_cnn do |cnn|
      cnn.query "SELECT '-170141183460469231731687303715884105728'::HUGEINT, '170141183460469231731687303715884105727'::HUGEINT, 18446744073709551615::UBIGINT, NULL::TIMESTAMP, TIMESTAMP '2020-01-02 03:04:05.000006'" do |rs|
        rs.move_next
        rs.read(Int128).should eq(Int128::MIN)
        rs.read(Int128).should eq(Int128::MAX)
        rs.read(UInt64).should eq(UInt64::MAX)
        rs.read(Time?).should be_nil
        rs.read(Time).should eq(Time.utc(2020, 1, 2, 3, 4, 5, nanosecond: 6000))
      end
    end
  end
end

describe "DuckDB string_t ABI" do
  it "matches the helpers for all inline sizes and pointer strings, including embedded NULs" do
    sizeof(DuckDB::LibDuckDB::StringT).should eq(16)
    with_cnn do |cnn|
      lib_result = DuckDB::LibDuckDB::Result.new
      state = DuckDB::LibDuckDB.query(cnn, "SELECT CASE WHEN i % 3 = 0 AND i > 0 THEN chr(0) || repeat('x', i::INTEGER - 1) ELSE repeat('x', i::INTEGER) END FROM range(0, 40) t(i)", pointerof(lib_result))
      state.success?.should be_true
      chunk = DuckDB::LibDuckDB.fetch_chunk(lib_result)
      begin
        view = DuckDB::ChunkView.new(chunk)
        vector = view.vector(0)
        view.size.times do |row|
          ptr = (vector.data + row * 16).as(DuckDB::LibDuckDB::StringT*)
          length = DuckDB::LibDuckDB.string_t_length(ptr.value)
          (DuckDB::LibDuckDB.string_is_inlined(ptr.value) != 0).should eq(length <= 12)
          expected = String.new(DuckDB::LibDuckDB.string_t_data(ptr), length)
          vector.string(row).should eq(expected)
          vector.blob(row).should eq(expected.to_slice)
        end
      ensure
        DuckDB::LibDuckDB.destroy_data_chunk(pointerof(chunk))
        DuckDB::LibDuckDB.destroy_result(pointerof(lib_result))
      end
    end
  end
end
