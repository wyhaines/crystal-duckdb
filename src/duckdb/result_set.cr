class DuckDB::ResultSet < DB::ResultSet
  @result = LibDuckDB::Result.new
  @native_alive = false
  @chunk = Pointer(Void).null.as(LibDuckDB::DataChunk)
  @readers = [] of ColumnReader
  @column_names = [] of String
  @row_index = -1_i64
  @chunk_size = 0_i64
  @rows_read = 0_i64
  @column_index = 0
  @exhausted = false

  def initialize(statement : Statement | UnpreparedStatement)
    super(statement)
    connection = statement.connection.as(Connection)
    connection.check_query_allowed
    streaming = connection.stream_results && statement.is_a?(Statement)
    state = if statement.is_a?(Statement)
              streaming ? statement.execute_streaming(pointerof(@result)) : LibDuckDB.execute_prepared(statement, pointerof(@result))
            else
              LibDuckDB.query(connection, statement.command, pointerof(@result))
            end
    @native_alive = true
    begin
      check(state)
      LibDuckDB.column_count(self).times do |index|
        ptr = LibDuckDB.column_name(self, index)
        name = ptr.null? ? "" : String.new(ptr)
        @column_names << name
        @readers << ColumnReader.build(LibDuckDB.column_logical_type(self, index), name)
      end
      connection.register_result(self, streaming)
      statement.result_opened(self) if statement.is_a?(Statement)
    rescue ex
      destroy_native
      raise ex
    end
  end

  protected def do_close
    destroy_native
    connection = @statement.connection.as(Connection)
    connection.unregister_result(self)
    statement = @statement
    statement.result_closed(self) if statement.is_a?(Statement)
    super
  end

  def move_next : Bool
    check_open
    return false if @exhausted
    @row_index += 1
    while @row_index >= @chunk_size
      destroy_chunk
      @chunk = LibDuckDB.fetch_chunk(@result)
      if @chunk.null?
        check_error
        @exhausted = true
        @statement.connection.as(Connection).finish_stream(self)
        return false
      end
      chunk = DataChunk.new(@chunk)
      @chunk_size = chunk.size
      @row_index = 0_i64
      @readers.each_with_index { |reader, index| reader.bind(chunk.vector(index)) }
    end
    @column_index = 0
    @rows_read += 1
    true
  rescue ex
    close
    raise ex
  end

  def read
    reader = current_reader
    @column_index += 1
    reader.read(@row_index)
  rescue ex
    close
    raise ex
  end

  # Typed scalar reads avoid building the full DuckDB::Value union.
  def read(type : T.class) : T forall T
    {% begin %}
    {% scalar = T.union? ? T.union_types.reject { |member| member == Nil } : [T] %}
    {% supported = [Bool, Int8, Int16, Int32, Int64, Int128, UInt8, UInt16, UInt32, UInt64, UInt128, Float32, Float64, String, Bytes, UUID, DuckDB::Decimal, DuckDB::Date, DuckDB::TimeOfDay, DuckDB::TimeTZ, DuckDB::Timestamp, DuckDB::Interval, DuckDB::BigNum] %}
    {% if scalar.size == 1 && supported.includes?(scalar[0]) %}
      reader = current_reader
      if reader.is_a?(ScalarColumnReader({{scalar[0]}}))
        if reader.vector.null?(@row_index)
          {% if T.nilable? %}
            @column_index += 1
            return nil
          {% end %}
        else
          @column_index += 1
          return reader.read_value(@row_index)
        end
      end
    {% end %}
    reader = current_reader
    column_index = @column_index
    @column_index += 1
    reader.read_as(@row_index, type, column_index)
    {% end %}
  rescue ex : DB::ColumnTypeMismatchError
    # crystal-db permits recovering from a typed mismatch at the next column.
    raise ex
  rescue ex
    close
    raise ex
  end

  def column_count : Int32
    check_open
    @readers.size
  end

  def column_name(index : Int32) : String
    check_open
    @column_names[index]? || ""
  end

  def next_column_index : Int32
    check_open
    @column_index
  end

  def to_unsafe
    pointerof(@result)
  end

  private def current_reader : ColumnReader
    check_open
    if @chunk.null? || @row_index < 0 || @exhausted
      raise Exception.new("Result is not positioned on a row")
    end
    @readers[@column_index]? || raise Exception.new("No more columns in this row")
  end

  private def check_open
    raise Exception.new("Result set is closed") if closed?
  end

  private def destroy_chunk
    LibDuckDB.destroy_data_chunk(pointerof(@chunk)) unless @chunk.null?
  end

  private def destroy_native
    return unless @native_alive
    @native_alive = false
    destroy_chunk
    @readers.each &.close
    @readers.clear
    LibDuckDB.destroy_result(self)
  end

  private def check(state : LibDuckDB::State)
    unless state.success?
      check_error
      raise Exception.new("Error with command `#{@statement.command}`")
    end
  end

  private def check_error
    ptr = LibDuckDB.result_error(self)
    raise Exception.new(String.new(ptr)) unless ptr.null?
  end
end
