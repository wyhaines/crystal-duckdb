# :nodoc:
# Borrowed view. ResultSet owns and destroys the handle; no view may outlive it.
struct DuckDB::DataChunk
  getter size : Int64
  getter column_count : Int32

  def initialize(@handle : LibDuckDB::DataChunk)
    @size = LibDuckDB.data_chunk_get_size(@handle).to_i64
    @column_count = LibDuckDB.data_chunk_get_column_count(@handle).to_i32
  end

  def vector(index : Int32) : Vector
    Vector.new(LibDuckDB.data_chunk_get_vector(@handle, index.to_u64))
  end
end
