# A borrowed column or nested child, valid only during its each_chunk iteration.
# Typed reads require the matching SQL type and a non-NULL, in-range row.
# Use null? before a typed read; value returns nil for NULL.
struct DuckDB::Vector
  @type : LibDuckDB::Type
  @view : VectorView
  @size : Int64

  # :nodoc:
  def initialize(@reader : ColumnReader, @lease : ChunkLease)
    @type = @reader.type
    @view = @reader.vector
    @size = @reader.row_count
  end

  # Returns whether the row is NULL; raises for an invalid row or expired chunk.
  def null?(row : Int) : Bool
    check_row(row)
    @type.sqlnull? || @view.null?(row.to_i64)
  end

  {% for method, info in {
    bool: {Bool, ["BOOLEAN"]},
    int8: {Int8, ["TINYINT"]}, int16: {Int16, ["SMALLINT"]}, int32: {Int32, ["INTEGER"]}, int64: {Int64, ["BIGINT"]}, int128: {Int128, ["HUGEINT"]},
    uint8: {UInt8, ["UTINYINT"]}, uint16: {UInt16, ["USMALLINT"]}, uint32: {UInt32, ["UINTEGER"]}, uint64: {UInt64, ["UBIGINT"]}, uint128: {UInt128, ["UHUGEINT"]},
    float32: {Float32, ["FLOAT"]}, float64: {Float64, ["DOUBLE"]},
    string: {String, ["VARCHAR", "ENUM", "BIT"]}, bytes: {Bytes, ["BLOB", "GEOMETRY"]},
    decimal: {DuckDB::Decimal, ["DECIMAL"]}, uuid: {UUID, ["UUID"]}, date: {DuckDB::Date, ["DATE"]},
    time_of_day: {DuckDB::TimeOfDay, ["TIME", "TIME_NS"]}, time_tz: {DuckDB::TimeTZ, ["TIME_TZ"]},
    timestamp: {DuckDB::Timestamp, ["TIMESTAMP", "TIMESTAMP_S", "TIMESTAMP_MS", "TIMESTAMP_NS", "TIMESTAMP_TZ", "TIMESTAMP_TZ_NS"]},
    interval: {DuckDB::Interval, ["INTERVAL"]}, big_num: {DuckDB::BigNum, ["BIGNUM"]},
  } %}
    # Reads a non-NULL scalar from its matching SQL type. Strings and bytes are copied.
    def {{method.id}}(row : Int) : {{info[0]}}
      check_row(row)
      unless {% for kind, i in info[1] %} {% if i > 0 %} || {% end %} @type == LibDuckDB::Type::{{kind.id}} {% end %}
        raise Exception.new("Cannot read {{method.id}} from #{@type}")
      end
      raise Exception.new("Cannot read {{method.id}} from NULL") if @view.null?(row.to_i64)
      {% if info[1].size == 1 && [Int8, Int16, Int32, Int64, UInt8, UInt16, UInt32, UInt64, Float32, Float64].includes?(info[0]) %}
        @view.get(row.to_i64, {{info[0]}})
      {% elsif info[0] == Bool %}
        @view.get(row.to_i64, UInt8) != 0
      {% else %}
        @reader.as(ScalarColumnReader({{info[0]}})).read_value(row.to_i64)
      {% end %}
    end
  {% end %}

  # Reads an owned scalar or recursive container through the result's reader tree.
  def value(row : Int) : DuckDB::Value
    check_row(row)
    @reader.read(row.to_i64)
  end

  # Yields borrowed BLOB or GEOMETRY bytes, valid only inside this inner block.
  # The buffer stays alive until callback exit even if the connection closes.
  # Do not retain or mutate the slice. NULL and type mismatches raise.
  def with_bytes(row : Int, & : Bytes ->) : Nil
    check_value(row)
    unless @type.blob? || @type.geometry?
      raise Exception.new("Cannot read bytes from #{@type}")
    end
    @lease.borrow do
      pointer, length = @view.string_data(row.to_i64)
      yield Bytes.new(pointer, length.to_i)
    end
  end

  # Yields borrowed UTF-8 VARCHAR bytes, valid only inside this inner block.
  # The buffer stays alive until callback exit even if the connection closes.
  # Do not retain or mutate the slice. NULL and type mismatches raise.
  def with_string_bytes(row : Int, & : Bytes ->) : Nil
    check_value(row)
    raise Exception.new("Cannot read string bytes from #{@type}") unless @type.varchar?
    @lease.borrow do
      pointer, length = @view.string_data(row.to_i64)
      yield Bytes.new(pointer, length.to_i)
    end
  end

  # Length of a non-NULL LIST, MAP or fixed ARRAY row.
  def list_size(row : Int) : Int64
    offset, length = list_entry(row)
    length
  end

  # Yields the child vector and its absolute row index for each element.
  # MAP elements are STRUCT(key, value). NULL containers raise; empty ones yield nothing.
  def each_list_value(row : Int, & : Vector, Int64 ->) : Nil
    offset, length = list_entry(row)
    child = Vector.new(@reader.children[0], @lease)
    length.times do |i|
      @lease.check
      yield child, offset + i
    end
  end

  # Borrows a zero-based STRUCT field. Check the parent's null? before reading it.
  def struct_child(index : Int) : Vector
    @lease.check
    raise Exception.new("Cannot read struct child from #{@type}") unless @type.struct?
    unless 0 <= index < @reader.children.size
      raise Exception.new("Struct field index #{index} is outside the struct")
    end
    Vector.new(@reader.children[index], @lease)
  end

  # Borrows a named STRUCT field, with the same row indices as its parent.
  def struct_child(name : String) : Vector
    @lease.check
    index = @reader.child_names.index(name) || raise Exception.new("Unknown struct field '#{name}'")
    struct_child(index)
  end

  # Borrows a fixed ARRAY's flat child. Element j of row i is at i * list_size(i) + j.
  # Check the parent's null? before reading its elements.
  def array_child : Vector
    @lease.check
    raise Exception.new("Cannot read array child from #{@type}") unless @type.array?
    Vector.new(@reader.children[0], @lease)
  end

  @[AlwaysInline]
  private def check_row(row : Int)
    @lease.check
    raise Exception.new("Row #{row} is outside the vector") unless 0 <= row < @size
  end

  private def check_value(row : Int)
    check_row(row)
    raise Exception.new("Cannot read NULL") if @type.sqlnull? || @view.null?(row.to_i64)
  end

  private def list_entry(row : Int) : Tuple(Int64, Int64)
    check_value(row)
    if @type.array?
      {row.to_i64 * @reader.array_size.to_i64, @reader.array_size.to_i64}
    elsif @type.list? || @type.map?
      entry = @view.get(row.to_i64, LibDuckDB::ListEntry)
      {entry.offset.to_i64, entry.length.to_i64}
    else
      raise Exception.new("Cannot read list from #{@type}")
    end
  end
end
