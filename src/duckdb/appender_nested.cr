class DuckDB::Appender
  # Appends an Array as LIST, or as a fixed ARRAY with a checked length.
  # Children follow the destination's types recursively, preserving exact leaves.
  def <<(value : Array)
    append_nested_value(value)
  end

  # Appends a Slice as LIST or fixed ARRAY. Bytes retains its BLOB overload.
  def <<(value : Slice)
    append_nested_value(value)
  end

  # Appends a StaticArray as LIST or a destination-sized fixed ARRAY.
  def <<(value : StaticArray)
    append_nested_value(value)
  end

  # Appends a Hash as MAP, or as STRUCT with exact String field names and count.
  # MAP keys must be non-NULL; values and STRUCT fields may be NULL.
  def <<(value : Hash)
    append_nested_value(value)
  end

  # Appends named fields to STRUCT, checking names and count before native calls.
  def <<(value : NamedTuple)
    append_nested_value(value)
  end

  private def append_nested_value(value)
    # Fetch the current column's full logical type, including nested metadata.
    destination = LibDuckDB.appender_column_type(self, @column_index.to_u64)
    begin
      raise Exception.new("No appender column at index #{@column_index}") if destination.null?
      append_owned_value(ValueBuilder.build(value, destination))
    ensure
      LibDuckDB.destroy_logical_type(pointerof(destination)) unless destination.null?
    end
  end
end
