struct DuckDB::Timestamp
  # Microseconds since the epoch, without narrowing DuckDB's range.
  getter microseconds : Int64

  delegate year, month, day, to: date
  delegate hour, minute, second, millisecond, microsecond, subsecond?, submillisecond?, to: time_of_day

  def initialize(date : Date, time_of_day : TimeOfDay)
    @microseconds = date.days.to_i64 * 86_400_000_000_i64 +
                    time_of_day.hour.to_i64 * 3_600_000_000_i64 +
                    time_of_day.minute.to_i64 * 60_000_000_i64 +
                    time_of_day.second.to_i64 * 1_000_000_i64 + time_of_day.microsecond
  end

  def initialize(time : Time)
    raise ArgumentError.new("Time is not in UTC") unless time.utc?
    @microseconds = time.to_unix * 1_000_000_i64 + time.nanosecond // 1000
  end

  def initialize(string : String)
    strings = string.split(" ")
    initialize(Date.new(strings[0]), TimeOfDay.new(strings[1]))
  end

  def initialize(@microseconds : Int64)
  end

  def date : Date
    check_finite
    Date.new((@microseconds // 86_400_000_000_i64).to_i32)
  end

  def time_of_day : TimeOfDay
    check_finite
    TimeOfDay.new(@microseconds % 86_400_000_000_i64)
  end

  def ==(other : self) : Bool
    @microseconds == other.microseconds
  end

  def to_s
    return "infinity" if @microseconds == Int64::MAX
    return "-infinity" if @microseconds == -Int64::MAX
    "#{date.to_s} #{time_of_day.to_s}"
  end

  def to_time
    midnight = date.to_time
    midnight + Time::Span.new(seconds: (@microseconds % 86_400_000_000_i64) // 1_000_000,
      nanoseconds: (@microseconds % 1_000_000) * 1000)
  end

  # :nodoc:
  def to_unsafe
    LibDuckDB::Timestamp.new(micros: @microseconds)
  end

  private def check_finite
    if @microseconds == Int64::MAX || @microseconds == -Int64::MAX
      raise Exception.new("Cannot convert an infinite DuckDB timestamp to calendar fields or Time")
    end
  end
end
