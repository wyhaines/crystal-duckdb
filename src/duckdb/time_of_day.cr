# TIME and TIME_NS, including DuckDB's valid end-of-day value 24:00:00.
struct DuckDB::TimeOfDay
  NANOSECONDS_PER_DAY = 86_400_000_000_000_i64

  getter nanoseconds : Int64

  def initialize(hour : Int32, minute : Int32, second : Int32 = 0, microsecond : Int32 = 0)
    unless 0 <= hour <= 24 && 0 <= minute < 60 && 0 <= second < 60 && 0 <= microsecond < 1_000_000 &&
           (hour != 24 || (minute == 0 && second == 0 && microsecond == 0))
      raise ArgumentError.new("Invalid time of day values")
    end
    @nanoseconds = ((hour.to_i64 * 3600 + minute * 60 + second) * 1_000_000 + microsecond) * 1000
  end

  def initialize(time : Time)
    raise ArgumentError.new("Time is not in UTC") unless time.utc?
    @nanoseconds = (time.hour.to_i64 * 3600 + time.minute * 60 + time.second) * 1_000_000_000 + time.nanosecond
  end

  def initialize(span : Time::Span)
    raise ArgumentError.new("Time span must be nonnegative and less than one day") unless Time::Span.zero <= span < 1.day
    @nanoseconds = span.to_i * 1_000_000_000 + span.nanoseconds
  end

  def initialize(string : String)
    match = /\A(\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,9}))?\z/.match(string)
    raise ArgumentError.new("Invalid time of day") unless match
    base = TimeOfDay.new(match[1].to_i, match[2].to_i, match[3].to_i)
    @nanoseconds = base.nanoseconds + (match[4]?.try(&.ljust(9, '0').to_i64) || 0_i64)
    validate
  end

  # Microseconds since midnight, retained for compatibility.
  def initialize(microseconds : Int64)
    unless 0 <= microseconds <= NANOSECONDS_PER_DAY // 1000
      raise ArgumentError.new("Microseconds must be within 00:00:00..24:00:00")
    end
    @nanoseconds = microseconds * 1000
  end

  def self.from_nanoseconds(nanoseconds : Int64) : self
    new(nanoseconds: nanoseconds)
  end

  private def initialize(*, @nanoseconds : Int64)
    validate
  end

  private def validate
    unless 0 <= @nanoseconds <= NANOSECONDS_PER_DAY
      raise ArgumentError.new("Nanoseconds must be within 00:00:00..24:00:00")
    end
  end

  def hour : Int32
    (@nanoseconds // 3_600_000_000_000).to_i32
  end

  def minute : Int32
    (@nanoseconds // 60_000_000_000 % 60).to_i32
  end

  def second : Int32
    (@nanoseconds // 1_000_000_000 % 60).to_i32
  end

  def nanosecond : Int32
    (@nanoseconds % 1_000_000_000).to_i32
  end

  def microsecond : Int32
    nanosecond // 1000
  end

  def millisecond : Int32
    nanosecond // 1_000_000
  end

  def subsecond? : Bool
    nanosecond > 0
  end

  def submillisecond? : Bool
    nanosecond < 1_000_000
  end

  def_equals_and_hash @nanoseconds

  def to_s(io : IO) : Nil
    io << hour.to_s.rjust(2, '0') << ':' << minute.to_s.rjust(2, '0') << ':' << second.to_s.rjust(2, '0')
    io << '.' << nanosecond.to_s.rjust(9, '0').rstrip('0') unless nanosecond.zero?
  end

  def to_span : Time::Span
    Time::Span.new(seconds: @nanoseconds // 1_000_000_000, nanoseconds: nanosecond)
  end

  # :nodoc:
  def to_unsafe
    raise Exception.new("TIME binding would lose nanoseconds; cast a TIME_NS parameter instead") unless @nanoseconds % 1000 == 0
    LibDuckDB::Time.new(micros: @nanoseconds // 1000)
  end
end
