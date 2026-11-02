# :nodoc:
# Data and validity are cached once when binding a chunk. All returned values
# are copied, so no String or Bytes escapes with a pointer into the chunk.
struct DuckDB::VectorView
  getter handle : LibDuckDB::Vector
  getter data : UInt8*
  @validity : UInt64*

  def initialize(@handle : LibDuckDB::Vector)
    @data = LibDuckDB.vector_get_data(@handle).as(UInt8*)
    @validity = LibDuckDB.vector_get_validity(@handle)
  end

  def self.empty
    new
  end

  private def initialize
    @handle = Pointer(Void).null.as(LibDuckDB::Vector)
    @data = Pointer(UInt8).null
    @validity = Pointer(UInt64).null
  end

  def null?(row : Int64) : Bool
    !@validity.null? && (@validity[row // 64] & (1_u64 << (row % 64))) == 0
  end

  def get(row : Int64, type : T.class) : T forall T
    @data.as(T*)[row]
  end

  # duckdb_string_t: uint32 length, then 12 inline bytes, or a prefix and
  # pointer at offset 8. The ABI spec compares both branches to C helpers.
  def string_data(row : Int64) : Tuple(UInt8*, UInt32)
    entry = @data + row * 16
    length = entry.as(UInt32*).value
    bytes = length <= 12 ? entry + 4 : (entry + 8).as(UInt8**).value
    {bytes, length}
  end

  def string(row : Int64) : String
    bytes, length = string_data(row)
    String.new(bytes, length)
  end

  def blob(row : Int64) : Bytes
    bytes, length = string_data(row)
    Bytes.new(length.to_i).tap { |copy| copy.copy_from(bytes, length) }
  end
end
