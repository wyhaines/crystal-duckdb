require "../spec_helper"
require "../support/lifecycle"

# Test-only inspection: a retained, expired Vector must not retain cache entries.
class DuckDB::ResultSet
  def string_readers_for_spec
    @readers
  end

  def corrupt_string_row_for_spec
    @readers.each do |reader|
      bytes, length = reader.vector.string_data(@row_index)
      bytes[length - 1] = 195_u8
    end
  end
end

struct DuckDB::Vector
  def string_view_for_spec
    @view
  end
end

class DuckDB::ScalarColumnReader(T)
  def string_cache_for_spec
    @string_cache
  end
end

class DuckDB::StringCache
  def slots_for_spec
    @entries.size
  end
end

native_lifetime do
  private def string_handles
    {NativeLifetime.results, NativeLifetime.statements, NativeLifetime.chunks,
     NativeLifetime.logical_types, NativeLifetime.values, NativeLifetime.appenders}
  end
end

describe "DuckDB VARCHAR reads" do
  it "filters the opt-in option from DuckDB settings and propagates it through pools" do
    options = DuckDB::Connection::Options.from_uri(URI.parse("duckdb::memory:?deduplicate_strings=true&stream_results=true&threads=1&prepared_statements_cache=false"))
    options.deduplicate_strings.should be_true
    options.stream_results.should be_true
    options.config_params.should eq({"threads" => "1"})
    DuckDB::Connection::Options.from_uri(URI.parse("duckdb::memory:")).deduplicate_strings.should be_false
    DuckDB::Connection::Options.from_uri(URI.parse("duckdb::memory:?deduplicate_strings=false")).deduplicate_strings.should be_false
    DuckDB::Connection::Options.from_uri(URI.parse("duckdb::memory:?deduplicate_strings=TRUE")).deduplicate_strings.should be_true
    expect_raises(ArgumentError, /deduplicate_strings/) do
      DuckDB::Connection::Options.from_uri(URI.parse("duckdb::memory:?deduplicate_strings=yes"))
    end
    DB.open "duckdb::memory:?deduplicate_strings=true&threads=1&prepared_statements_cache=false" do |db|
      db.using_connection { |cnn| cnn.as(DuckDB::Connection).deduplicate_strings.should be_true }
      db.query("SELECT 'pooled' FROM range(2)") do |rs|
        rs.move_next.should be_true
        first = rs.read(String)
        rs.move_next.should be_true
        rs.read(String).should be(first)
      end
    end
  end

  it "captures the connection property per result and keeps separate result caches" do
    DB.connect "duckdb::memory:?threads=1&prepared_statements_cache=false" do |db|
      cnn = db.as(DuckDB::Connection)
      cnn.deduplicate_strings.should be_false
      cnn.deduplicate_strings = true
      first_result = cnn.query("SELECT 'shared value' FROM range(2)")
      second_result = cnn.query("SELECT 'shared value' FROM range(2)")
      cnn.deduplicate_strings = false
      first_result.move_next.should be_true
      first = first_result.read(String)
      first_result.move_next.should be_true
      first_result.read(String).should be(first)
      second_result.move_next.should be_true
      second_result.read(String).should_not be(first)
      first_result.close
      second_result.close
      cnn.query("SELECT 'shared value' FROM range(2)") do |rs|
        rs.move_next.should be_true
        plain = rs.read(String)
        rs.move_next.should be_true
        rs.read(String).should_not be(plain)
      end
    end
  end

  [false, true].each do |dedup|
    [false, true].each do |stream|
      it "preserves typed, nullable, untyped, chunk and nested reads (dedup=#{dedup}, stream=#{stream})" do
        DB.connect "duckdb::memory:?threads=1&prepared_statements_cache=false&deduplicate_strings=#{dedup}&stream_results=#{stream}" do |db|
          cnn = db.as(DuckDB::Connection)
          before = native_lifetime { string_handles }
          expected = ["", "a", "\0x\0", "x" * 12, "prefix\0" + "m" * 25, "l" * 200, "é\0日本語", nil]
          cnn.exec "CREATE TABLE texts (id INTEGER, s VARCHAR)"
          expected.each_with_index { |s, id| cnn.exec "INSERT INTO texts VALUES (?, ?)", id, s }
          sql = "SELECT s, s, s FROM range(7000) t(i) JOIN texts ON id = i % 8 ORDER BY i"
          seen = Hash(String, String).new
          row = 0
          cnn.query(sql) do |rs|
            rs.each do
              value = expected[row % expected.size]
              if value
                typed = rs.read(String)
                typed.to_slice.should eq(value.to_slice)
                if dedup && (previous = seen[typed]?)
                  typed.should be(previous)
                end
                seen[typed] = typed
              else
                # A typed NULL mismatch still allows reading the next column.
                expect_raises(DB::ColumnTypeMismatchError) { rs.read(String) }
              end
              rs.read(String?).should eq(value)
              rs.read.should eq(value)
              row += 1
            end
          end
          row.should eq(7000)
          row = 0
          seen.clear
          cnn.each_chunk("SELECT s FROM range(7000) t(i) JOIN texts ON id = i % 8 ORDER BY i", stream: stream) do |chunk|
            vector = chunk[0]
            chunk.size.times do |r|
              value = expected[row % expected.size]
              vector.value(r).should eq(value)
              if value
                string = vector.string(r)
                string.to_slice.should eq(value.to_slice)
                vector.with_string_bytes(r) { |b| b.should eq(value.to_slice) }
                if dedup && (previous = seen[string]?)
                  string.should be(previous)
                end
                seen[string] = string
              else
                vector.null?(r).should be_true
                expect_raises(DuckDB::Exception, /NULL/) { vector.string(r) }
              end
              row += 1
            end
          end
          row.should eq(7000)
          cnn.query("SELECT [['a', NULL, 'a'], ['long string with NUL' || chr(0), 'a']] FROM range(3000)") do |rs|
            first = nil.as(String?)
            rs.each do
              lists = rs.read(Array(Array(String?)))
              lists.should eq([["a", nil, "a"], ["long string with NUL\0", "a"]])
              if dedup
                value = lists[0][0].not_nil!
                lists[0][2].should be(value)
                lists[1][1].should be(value)
                value.should be(first) if first
                first = value
              end
            end
          end
          native_lifetime { string_handles.should eq(before) }
        end
      end
    end

    it "keeps ENUM, BIT and independent BLOB copies unchanged (dedup=#{dedup})" do
      DB.connect "duckdb::memory:?threads=1&prepared_statements_cache=false&deduplicate_strings=#{dedup}" do |db|
        reads = native_lifetime { NativeLifetime.enum_dictionary_reads }
        db.query("SELECT 'blue'::ENUM('red','blue'), '101001'::BIT, encode('a' || chr(0) || 'b') FROM range(5000)") do |rs|
          rs.as(DuckDB::ResultSet).string_readers_for_spec.first(2).each do |reader|
            reader.as(DuckDB::ScalarColumnReader(String)).string_cache_for_spec.should be_nil
          end
          first_enum = nil.as(String?)
          first_blob = nil.as(Bytes?)
          rs.each do
            value = rs.read(String)
            value.should eq("blue")
            value.should be(first_enum) if first_enum
            first_enum = value
            rs.read(String).should eq("101001")
            blob = rs.read(Bytes)
            blob.should eq(Bytes[97, 0, 98])
            blob.to_unsafe.should_not eq(first_blob.not_nil!.to_unsafe) if first_blob
            first_blob = blob
          end
        end
        native_lifetime { NativeLifetime.enum_dictionary_reads.should eq(reads + 2) }
      end
    end
  end

  [false, true].each do |dedup|
    it "preserves invalid UTF-8 vectors, including RE2 byte captures on 1.5 (dedup=#{dedup})" do
      DB.connect "duckdb::memory:?threads=1&prepared_statements_cache=false&deduplicate_strings=#{dedup}" do |db|
        cnn = db.as(DuckDB::Connection)
        before = native_lifetime { string_handles }
        # RE2's \C captures a single byte, including part of a UTF-8 character.
        # These are real VARCHAR results from valid SQL and valid input strings.
        projection = "SELECT regexp_extract('a' || chr(0) || 'é', 'a\\C\\C') AS short, regexp_extract(repeat('x',199) || 'é', 'x+\\C') AS long FROM range(5000)"
        inject_bytes = cnn.scalar("SELECT version()").as(String).starts_with?("v2.")
        if inject_bytes
          # 2.0 validates RE2 output. Use an unchecked C vector write to exercise
          # the driver's byte-preserving behaviour on that version as well.
          expect_raises(DuckDB::Exception, /not valid UTF-8/) { cnn.query(projection) { |_| } }
          projection = "SELECT 'a' || chr(0) || 'x' AS short, repeat('x',200) AS long FROM range(5000)"
        end
        expected = [String.new(Bytes[97, 0, 195]), "x" * 199 + String.new(Bytes[195])]
        cnn.query("SELECT short, long, short, long FROM (#{projection})") do |rs|
          rs.each do
            rs.as(DuckDB::ResultSet).corrupt_string_row_for_spec if inject_bytes
            rs.read(String).to_slice.should eq(expected[0].to_slice)
            rs.read(String?).not_nil!.to_slice.should eq(expected[1].to_slice)
            rs.read.as(String).to_slice.should eq(expected[0].to_slice)
            rs.read.as(String).valid_encoding?.should be_false
          end
        end
        cnn.each_chunk(projection) do |chunk|
          chunk.size.times do |row|
            2.times do |column|
              if inject_bytes
                bytes, length = chunk[column].string_view_for_spec.string_data(row.to_i64)
                bytes[length - 1] = 195_u8
              end
              chunk[column].string(row).to_slice.should eq(expected[column].to_slice)
              chunk[column].with_string_bytes(row) { |bytes| bytes.should eq(expected[column].to_slice) }
            end
          end
        end
        native_lifetime { string_handles.should eq(before) }
      end
    end
  end

  it "ignores unspecified inline padding for every inline length" do
    DB.connect "duckdb::memory:?threads=1&prepared_statements_cache=false&deduplicate_strings=true" do |db|
      cnn = db.as(DuckDB::Connection)
      (0..12).each do |length|
        cnn.each_chunk("SELECT repeat('a', #{length}) FROM range(2)") do |chunk|
          vector = chunk[0]
          view = vector.string_view_for_spec
          # Deliberately give equal strings different unused duckdb_string_t bytes.
          (4 + length...16).each do |offset|
            view.data[offset] = 0x55_u8
            view.data[16 + offset] = 0xaa_u8
          end
          first = vector.string(0)
          first.should eq("a" * length)
          vector.string(1).should be(first)
        end
      end
    end
  end

  it "releases bounded caches on saturation, early close and connection close" do
    DB.connect "duckdb::memory:?threads=1&prepared_statements_cache=false&deduplicate_strings=true" do |db|
      cnn = db.as(DuckDB::Connection)
      before = native_lifetime { string_handles }
      rs = cnn.query("SELECT 'retained long string with bytes' FROM range(5000)").as(DuckDB::ResultSet)
      reader = rs.string_readers_for_spec[0].as(DuckDB::ScalarColumnReader(String))
      cache = reader.string_cache_for_spec.not_nil!
      rs.move_next.should be_true
      retained = rs.read(String)
      cache.size.should eq(1)
      rs.close
      cache.size.should eq(0)
      cache.retained_bytes.should eq(0)
      cache.slots_for_spec.should eq(0)
      retained.should eq("retained long string with bytes")
      native_lifetime { string_handles.should eq(before) }
      rs = cnn.query("SELECT i::VARCHAR FROM range(20000) t(i)").as(DuckDB::ResultSet)
      cache = rs.string_readers_for_spec[0].as(DuckDB::ScalarColumnReader(String)).string_cache_for_spec.not_nil!
      i = 0
      rs.each do
        rs.read(String).should eq(i.to_s)
        cache.size.should be <= DuckDB::StringCache::MAX_ENTRIES
        cache.retained_bytes.should be <= DuckDB::StringCache::MAX_BYTES
        i += 1
      end
      cache.slots_for_spec.should eq(0)
      rs.close
      native_lifetime { string_handles.should eq(before) }
      rs = cnn.query("SELECT repeat('x', 2200000) || i::VARCHAR FROM range(3) t(i)").as(DuckDB::ResultSet)
      cache = rs.string_readers_for_spec[0].as(DuckDB::ScalarColumnReader(String)).string_cache_for_spec.not_nil!
      rs.each { rs.read(String).bytesize.should eq(2200001) }
      cache.slots_for_spec.should eq(0)
      cache.retained_bytes.should be <= DuckDB::StringCache::MAX_BYTES
      cnn.close
      cache.slots_for_spec.should eq(0)
    end
  end

  it "propagates explicit options and both new and reused connection owners" do
    options = DuckDB::Connection::Options.new(":memory:", {"threads" => "1"}, false, true)
    connection = DuckDB::Connection.new(DB::Connection::Options.new, options)
    connection.deduplicate_strings.should be_true
    connection.close
    builder = DuckDB::Driver.new.connection_builder(URI.parse("duckdb::memory:?threads=1&deduplicate_strings=true"))
    first = builder.build.as(DuckDB::Connection)
    second = builder.build.as(DuckDB::Connection)
    first.deduplicate_strings.should be_true
    second.deduplicate_strings.should be_true
    first.exec "CREATE TABLE shared_owner (v INTEGER)"
    second.scalar("SELECT count(*) FROM shared_owner").should eq(0)
    first.close
    second.close
    third = builder.build.as(DuckDB::Connection)
    third.deduplicate_strings.should be_true
  ensure
    connection.try &.close
    first.try &.close
    second.try &.close
    third.try &.close
    builder.try &.close
  end

  it "allocates tables only for non-NULL leaves that are actually read" do
    DB.connect "duckdb::memory:?threads=1&prepared_statements_cache=false&deduplicate_strings=true" do |db|
      before = native_lifetime { string_handles }
      columns = (0...20).map { |i| "'small'::VARCHAR AS s#{i}" }.join(", ")
      ["SELECT #{columns} WHERE false", "SELECT #{columns}"].each do |sql|
        rs = db.query(sql).as(DuckDB::ResultSet)
        caches = rs.string_readers_for_spec.map { |r| r.as(DuckDB::ScalarColumnReader(String)).string_cache_for_spec.not_nil! }
        caches.each { |cache| cache.slots_for_spec.should eq(0) }
        if rs.move_next
          caches.each { |cache| cache.slots_for_spec.should eq(0) }
          rs.read(String).should eq("small")
          caches[0].slots_for_spec.should eq(DuckDB::StringCache::INITIAL_CAPACITY)
          caches.skip(1).each { |cache| cache.slots_for_spec.should eq(0) }
          19.times { rs.read(String).should eq("small") }
          caches.each { |cache| cache.slots_for_spec.should eq(DuckDB::StringCache::INITIAL_CAPACITY) }
        end
        rs.close
        caches.each { |cache| cache.slots_for_spec.should eq(0) }
      end
      nulls = (0...20).map { |i| "NULL::VARCHAR AS s#{i}" }.join(", ")
      db.query("SELECT #{nulls}") do |rs|
        rs.move_next.should be_true
        20.times { rs.read(String?).should be_nil }
        rs.as(DuckDB::ResultSet).string_readers_for_spec.each do |reader|
          reader.as(DuckDB::ScalarColumnReader(String)).string_cache_for_spec.not_nil!.slots_for_spec.should eq(0)
        end
      end
      native_lifetime { string_handles.should eq(before) }
    end
  end

  it "preserves values and identity across growth and disables at saturation" do
    [12, 200].each do |length|
      DB.connect "duckdb::memory:?threads=1&prepared_statements_cache=false&deduplicate_strings=true" do |db|
        before = native_lifetime { string_handles }
        limit = DuckDB::StringCache::MAX_ENTRIES
        sql = "SELECT lpad((CASE WHEN i < #{limit * 2} THEN i % #{limit} WHEN i < #{limit * 2 + 2} THEN #{limit} ELSE 0 END)::VARCHAR, #{length}, 'x') FROM range(#{limit * 2 + 4}) t(i)"
        rs = db.query(sql).as(DuckDB::ResultSet)
        cache = rs.string_readers_for_spec[0].as(DuckDB::ScalarColumnReader(String)).string_cache_for_spec.not_nil!
        cache.slots_for_spec.should eq(0)
        originals = [] of String
        capacities = Set(Int32).new
        previous = nil.as(String?)
        row = 0
        rs.each do
          value = rs.read(String)
          id = row < limit * 2 ? row % limit : (row < limit * 2 + 2 ? limit : 0)
          value.should eq(id.to_s.rjust(length, 'x'))
          if row < limit
            originals << value
            capacities.add(cache.slots_for_spec)
          elsif row < limit * 2
            value.same?(originals[id]).should be_true
          else
            cache.slots_for_spec.should eq(0)
            value.same?(originals[0]).should be_false
            value.same?(previous).should be_false if previous
          end
          cache.size.should be <= limit
          cache.retained_bytes.should be <= DuckDB::StringCache::MAX_BYTES
          previous = value
          row += 1
        end
        capacities.size.should be >= 5
        capacities.should contain(DuckDB::StringCache::INITIAL_CAPACITY)
        capacities.should contain(DuckDB::StringCache::CAPACITY)
        row.should eq(limit * 2 + 4)
        rs.close
        native_lifetime { string_handles.should eq(before) }
      end
    end
  end

  it "keeps Crystal and native buffers alive across collections" do
    DB.connect "duckdb::memory:?threads=1&prepared_statements_cache=false&deduplicate_strings=true" do |db|
      cnn = db.as(DuckDB::Connection)
      cnn.exec "CREATE TABLE gc_texts (s VARCHAR, nested VARCHAR[])"
      cnn.appender("gc_texts") do |appender|
        appender.row do |r|
          r << ("dynamic\0" + "x" * 200)
          GC.collect
          r << ["nested\0" + "y" * 200]
        end
        GC.collect
      end
      cnn.query("SELECT s, nested FROM gc_texts, range(5000)") do |rs|
        i = 0
        rs.each do
          value = rs.read(String)
          GC.collect if i % 1024 == 0
          rs.read(Array(String)).should eq(["nested\0" + "y" * 200])
          value.should eq("dynamic\0" + "x" * 200)
          i += 1
        end
        i.should eq(5000)
      end
      expect_raises(DuckDB::Exception, /closed/) do
        cnn.each_chunk("SELECT s FROM gc_texts") do |chunk|
          vector = chunk[0]
          vector.with_string_bytes(0) do |bytes|
            cnn.close
            GC.collect
            bytes.should eq(("dynamic\0" + "x" * 200).to_slice)
          end
          expect_raises(DuckDB::Exception, /ended/) { vector.string(0) }
        end
      end
    end
  end
end
