# A borrowed result chunk, valid only during its each_chunk iteration.
# All methods raise DuckDB::Exception after the iteration ends.
struct DuckDB::DataChunk
  # :nodoc:
  def initialize(@size : Int64, @readers : Array(ColumnReader), @names : Array(String), @lease : ChunkLease)
  end

  # Number of rows in this chunk.
  def size : Int64
    @lease.check
    @size
  end

  # Number of columns in this chunk.
  def column_count : Int32
    @lease.check
    @readers.size
  end

  # Column name at the zero-based index; raises for an invalid index.
  def column_name(index : Int) : String
    reader(index)
    @names[index]
  end

  # Cached DuckDB type identifier at the zero-based index.
  def column_type(index : Int) : Type
    reader(index).type
  end

  # Borrows a column for this iteration; raises for an invalid index.
  def column(index : Int) : Vector
    Vector.new(reader(index), @lease)
  end

  # Borrows a column, equivalent to column(index).
  def [](index : Int) : Vector
    column(index)
  end

  private def reader(index : Int) : ColumnReader
    @lease.check
    raise Exception.new("Column index #{index} is outside the chunk") unless 0 <= index < @readers.size
    @readers[index]
  end
end

# :nodoc:
class DuckDB::ChunkLease
  @alive = true
  @borrows = 0
  @pending = Pointer(Void).null.as(LibDuckDB::DataChunk)

  @[AlwaysInline]
  def check
    raise Exception.new("Chunk iteration has ended") unless @alive
  end

  # A byte callback pins the chunk even if its result or connection closes.
  def borrow(& : ->) : Nil
    check
    @borrows += 1
    begin
      yield
    ensure
      @borrows -= 1
      destroy_pending if @borrows == 0
    end
  end

  def destroy(chunk : LibDuckDB::DataChunk)
    @alive = false
    @pending = chunk
    destroy_pending if @borrows == 0
  end

  private def destroy_pending
    LibDuckDB.destroy_data_chunk(pointerof(@pending)) unless @pending.null?
  end
end
