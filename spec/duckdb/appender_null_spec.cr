require "../spec_helper"

# Test-only: put garbage strings where DuckDB reads a NULL row's STRUCT and
# ARRAY children, so a NULL written into the chunk fails every time instead of
# depending on what the allocator left there.
class DuckDB::Appender
  def poison_nested_children_for_spec(row : Int32)
    struct_child = LibDuckDB.struct_vector_get_child(LibDuckDB.data_chunk_get_vector(@chunk, 1), 0)
    array_child = LibDuckDB.array_vector_get_child(LibDuckDB.data_chunk_get_vector(@chunk, 2))
    { {struct_child, row}, {array_child, row * 2}, {array_child, row * 2 + 1} }.each do |vector, index|
      entry = LibDuckDB.vector_get_data(vector).as(UInt8*) + index * 16
      entry.as(UInt32*).value = 1000_u32
      (entry + 8).as(UInt64*).value = 0x4b_u64
    end
  end
end

describe "DuckDB::Appender NULL nested values" do
  it "appends NULL STRUCT and ARRAY values through DuckDB, whatever the chunk's child memory holds" do
    with_cnn do |cnn|
      cnn.exec "CREATE TABLE poisoned (i INTEGER, s STRUCT(v VARCHAR), a VARCHAR[2])"
      cnn.appender("poisoned") do |appender|
        appender.poison_nested_children_for_spec(0)
        appender.row { |r| r << 1 << nil << nil }
        appender.poison_nested_children_for_spec(0)
        appender.row { |r| r << nil << nil << nil }
      end
      cnn.query_all("SELECT i, s IS NULL, a IS NULL FROM poisoned ORDER BY i NULLS LAST", as: {Int32?, Bool, Bool}).should eq([{1, true, true}, {nil, true, true}])
    end
  end

  it "round trips NULL and non-NULL nested values across chunk boundaries" do
    with_cnn do |cnn|
      cnn.exec "CREATE TABLE nested_nulls (i INTEGER, s STRUCT(v VARCHAR), a VARCHAR[2], m MAP(VARCHAR, VARCHAR), u UNION(t VARCHAR, n INTEGER), l VARCHAR[])"
      rows = 5000
      cnn.appender("nested_nulls") do |appender|
        rows.times do |i|
          appender.row do |r|
            r << i
            if i.even?
              r << nil << nil << nil << nil << nil
            else
              r << {v: "struct #{i}"} << ["a#{i}", "b#{i}"] << {"k#{i}" => "v#{i}"} << "union #{i}" << ["list #{i}"]
            end
          end
        end
      end
      cnn.query_all(<<-SQL, as: {Int64, Int64, Int64, Int64, Int64, Int64, Int64}).should eq([{5000_i64, 2500_i64, 2500_i64, 2500_i64, 2500_i64, 2500_i64, 2500_i64}])
        SELECT count(*),
          count(*) FILTER (i % 2 = 1 AND s.v = 'struct ' || i),
          count(*) FILTER (i % 2 = 1 AND a = ['a' || i, 'b' || i]::VARCHAR[2]),
          count(*) FILTER (i % 2 = 1 AND m['k' || i] = 'v' || i),
          count(*) FILTER (i % 2 = 1 AND u.t = 'union ' || i),
          count(*) FILTER (i % 2 = 1 AND l = ['list ' || i]),
          count(*) FILTER (i % 2 = 0 AND s IS NULL AND a IS NULL AND m IS NULL AND u IS NULL AND l IS NULL)
        FROM nested_nulls
        SQL
    end
  end

  it "rejects all-nil append_columns columns for nested destinations before appending" do
    with_cnn do |cnn|
      cnn.exec "CREATE TABLE nested_columns (i INTEGER, s STRUCT(v VARCHAR))"
      cnn.appender("nested_columns") do |appender|
        expect_raises(DuckDB::Exception, /Column 1 element type/) do
          appender.append_columns([1, 2], [nil, nil])
        end
        appender.row { |r| r << 4 << nil }
      end
      cnn.query_all("SELECT i, s IS NULL FROM nested_columns ORDER BY i", as: {Int32, Bool}).should eq([{4, true}])
    end
  end
end
