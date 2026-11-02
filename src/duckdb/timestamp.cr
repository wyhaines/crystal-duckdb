struct DuckDB::Timestamp
  # Int128 holds every Int64 seconds/milliseconds/microseconds/nanoseconds
  # variant without overflow. Infinity is independent of the finite count.
  getter nanoseconds : Int128
  getter infinity : Int8 = 0_i8
  getter? timezone : Bool = false

  delegate hour, minute, second, millisecond, microsecond, nanosecond, subsecond?, submillisecond?, to: time_of_day

  def initialize(date : Date, time_of_day : TimeOfDay)
    @infinity = date.infinite? ? (date.days > 0 ? 1_i8 : -1_i8) : 0_i8
    @nanoseconds = @infinity == 0 ? date.days.to_i128 * TimeOfDay::NANOSECONDS_PER_DAY + time_of_day.nanoseconds : 0_i128
  end

  def initialize(time : Time)
    raise ArgumentError.new("Time is not in UTC") unless time.utc?
    @nanoseconds = time.to_unix.to_i128 * 1_000_000_000 + time.nanosecond
  end

  def initialize(string : String)
    case string
    when "infinity"  then initialize(Int64::MAX)
    when "-infinity" then initialize(-Int64::MAX)
    else
      strings = string.split(' ', 2)
      initialize(Date.new(strings[0]), TimeOfDay.new(strings[1]))
    end
  end

  # Microseconds since the epoch, retained for compatibility.
  def initialize(microseconds : Int64)
    @infinity = microseconds == Int64::MAX ? 1_i8 : (microseconds == -Int64::MAX ? -1_i8 : 0_i8)
    @nanoseconds = @infinity == 0 ? microseconds.to_i128 * 1000 : 0_i128
  end

  def self.from_nanoseconds(nanoseconds : Int128, *, timezone : Bool = false) : self
    unless Int64::MIN.to_i128 * 1_000_000_000 <= nanoseconds <= (Int64::MAX.to_i128 - 1) * 1_000_000_000
      raise Exception.new("Timestamp is outside DuckDB's range")
    end
    new(nanoseconds: nanoseconds, timezone: timezone)
  end

  private def initialize(*, @nanoseconds : Int128, @infinity : Int8 = 0_i8, @timezone : Bool = false)
  end

  # :nodoc:
  def self.from_raw(value : Int64, type : LibDuckDB::Type) : self
    infinity = value == Int64::MAX ? 1_i8 : (value == -Int64::MAX ? -1_i8 : 0_i8)
    multiplier = case type
                 when .timestamp_s?  then 1_000_000_000
                 when .timestamp_ms? then 1_000_000
                 when .timestamp_ns?, .timestamp_tz_ns? then 1
                 else 1000
                 end
    new(nanoseconds: infinity == 0 ? value.to_i128 * multiplier : 0_i128,
      infinity: infinity, timezone: type.timestamp_tz? || type.timestamp_tz_ns?)
  end

  def infinite? : Bool
    @infinity != 0
  end

  # Exact when available, raising instead of silently dropping nanoseconds.
  def microseconds : Int64
    return @infinity > 0 ? Int64::MAX : -Int64::MAX if infinite?
    unless @nanoseconds % 1000 == 0 && -Int64::MAX < @nanoseconds // 1000 < Int64::MAX
      raise Exception.new("Timestamp cannot be represented exactly in microseconds")
    end
    (@nanoseconds // 1000).to_i64
  end

  def year : Int64
    calendar[0]
  end

  def month : Int32
    calendar[1]
  end

  def day : Int32
    calendar[2]
  end

  private def calendar
    check_finite
    Date.calendar(@nanoseconds // TimeOfDay::NANOSECONDS_PER_DAY)
  end

  def date : Date
    check_finite
    days = @nanoseconds // TimeOfDay::NANOSECONDS_PER_DAY
    unless -Int32::MAX < days < Int32::MAX
      raise Exception.new("Timestamp is outside DuckDB DATE's range")
    end
    Date.new(days.to_i32)
  end

  def time_of_day : TimeOfDay
    check_finite
    TimeOfDay.from_nanoseconds((@nanoseconds % TimeOfDay::NANOSECONDS_PER_DAY).to_i64)
  end

  # TZ is provenance: equality compares the instant, as in DuckDB.
  def_equals_and_hash @nanoseconds, @infinity

  def to_s(io : IO) : Nil
    if infinite?
      io << (@infinity > 0 ? "infinity" : "-infinity")
    else
      Date.format(io, @nanoseconds // TimeOfDay::NANOSECONDS_PER_DAY)
      io << ' ' << time_of_day
      io << "+00" if @timezone
    end
  end

  def to_time : Time
    check_finite
    seconds = @nanoseconds // 1_000_000_000
    unless -62_135_596_800_i64 <= seconds <= 253_402_300_799_i64
      raise Exception.new("Timestamp is outside Crystal Time's year range (1..9999)")
    end
    Time.unix(seconds.to_i64) + Time::Span.new(nanoseconds: (@nanoseconds % 1_000_000_000).to_i32)
  end

  # Duration since the Unix epoch, as documented by the original API.
  def to_span : Time::Span
    check_finite
    seconds = @nanoseconds // 1_000_000_000
    unless Int64::MIN <= seconds <= Int64::MAX
      raise Exception.new("Timestamp is outside Time::Span's range")
    end
    Time::Span.new(seconds: seconds.to_i64, nanoseconds: (@nanoseconds % 1_000_000_000).to_i32)
  end

  # :nodoc:
  def to_unsafe
    LibDuckDB::Timestamp.new(micros: microseconds)
  end

  private def check_finite
    raise Exception.new("Cannot convert an infinite DuckDB timestamp to calendar fields or Time") if infinite?
  end
end
