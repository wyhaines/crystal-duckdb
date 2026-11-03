# :nodoc:
# Result-local, per VARCHAR leaf. No pointer into DuckDB memory is retained.
# Tables start at the first read and grow at half full. At most 16,384 Strings
# and 4 MiB of payload plus a 32-byte allowance per String are retained. A miss
# beyond either limit drops the table and disables caching for this result.
class DuckDB::StringCache
  INITIAL_CAPACITY = 64
  CAPACITY = 32_768
  MAX_ENTRIES = CAPACITY // 2
  MAX_BYTES = 4 * 1024 * 1024

  private record Entry, first : UInt64, second : UInt64, hash : UInt64, value : String?

  @entries = Slice(Entry).empty
  @disabled = false
  getter size = 0
  getter retained_bytes = 0

  def clear
    @disabled = true
    @entries = Slice(Entry).empty
    @size = 0
    @retained_bytes = 0
  end

  def read(vector : VectorView, row : Int64) : String
    if @entries.empty?
      return vector.string(row) if @disabled
      @entries = table(INITIAL_CAPACITY)
    end
    entry = vector.data + row * 16
    length = entry.as(UInt32*).value
    if length <= 12
      # Ignore unspecified padding after the inline bytes. Both loads remain
      # inside duckdb_string_t; even empty strings never dereference a pointer.
      first = entry.as(UInt64*).value
      second = (entry + 8).as(UInt64*).value
      if length <= 4
        first &= UInt64::MAX >> ((4 - length) * 8)
        second = 0_u64
      else
        second &= UInt64::MAX >> ((12 - length) * 8)
      end
      # Avalanche high bytes into the low bucket bits as well. A single
      # multiply/shift clusters strings that differ only in their last bytes.
      hash = first ^ second
      hash = (hash ^ (hash >> 30)) &* 0xbf58476d1ce4e5b9_u64
      hash = (hash ^ (hash >> 27)) &* 0x94d049bb133111eb_u64
      hash ^= hash >> 31
      bytes = entry + 4
    else
      bytes = (entry + 8).as(UInt8**).value
      hash = Bytes.new(bytes, length.to_i).hash
      first = hash
      second = length.to_u64
    end
    index = (hash & (@entries.size - 1)).to_i
    loop do
      cached = @entries[index]
      if value = cached.value
        if cached.first == first && cached.second == second
          return value if value.bytesize == length && (length <= 12 || LibC.memcmp(value.to_unsafe, bytes, length) == 0)
        end
      else
        value = String.new(bytes, length)
        cost = value.bytesize.to_i64 + 32
        if @size >= MAX_ENTRIES || @retained_bytes.to_i64 + cost > MAX_BYTES
          clear
        else
          if @size >= @entries.size // 2
            grow
            index = (hash & (@entries.size - 1)).to_i
            while @entries[index].value
              index = (index + 1) & (@entries.size - 1)
            end
          end
          @entries[index] = Entry.new(first, second, hash, value)
          @size += 1
          @retained_bytes += cost.to_i
        end
        return value
      end
      index = (index + 1) & (@entries.size - 1)
    end
  end

  private def table(capacity : Int32) : Slice(Entry)
    Slice(Entry).new(capacity) { Entry.new(0_u64, 0_u64, 0_u64, nil) }
  end

  private def grow
    previous = @entries
    @entries = table(previous.size * 2)
    previous.each do |entry|
      next unless entry.value
      index = (entry.hash & (@entries.size - 1)).to_i
      while @entries[index].value
        index = (index + 1) & (@entries.size - 1)
      end
      @entries[index] = entry
    end
  end
end
