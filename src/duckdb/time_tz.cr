# A local time and a UTC offset in seconds (not a named timezone).
struct DuckDB::TimeTZ
  getter time_of_day : TimeOfDay
  getter offset : Int32

  def initialize(@time_of_day : TimeOfDay, @offset : Int32)
    raise ArgumentError.new("TIME_TZ offset is outside DuckDB's range") unless -57599 <= @offset <= 57599
    raise ArgumentError.new("TIME_TZ has microsecond precision") unless @time_of_day.nanoseconds % 1000 == 0
  end

  def_equals_and_hash @time_of_day, @offset

  def to_s(io : IO) : Nil
    io << @time_of_day << (@offset < 0 ? '-' : '+')
    offset = @offset.abs
    io << (offset // 3600).to_s.rjust(2, '0')
    if offset % 3600 != 0
      io << ':' << (offset // 60 % 60).to_s.rjust(2, '0')
      io << ':' << (offset % 60).to_s.rjust(2, '0') if offset % 60 != 0
    end
  end

  # :nodoc:
  def to_unsafe
    LibDuckDB.create_time_tz(@time_of_day.nanoseconds // 1000, @offset)
  end
end
