struct DuckDB::Date
  # Days since the epoch, including DuckDB's infinity sentinels.
  getter days : Int32

  def initialize(year : Int32, month : Int32, day : Int32)
    unless 1 <= year <= 9999 && 1 <= month <= 12 && 1 <= day <= Time.days_in_month(year, month)
      raise ArgumentError.new("Invalid date")
    end
    @days = ((Time.utc(year, month, day).to_unix) // 86_400).to_i32
  end

  def initialize(time : Time)
    initialize(time.year, time.month, time.day)
  end

  def initialize(string : String)
    case string
    when "infinity"  then initialize(Int32::MAX)
    when "-infinity" then initialize(-Int32::MAX)
    else
      initialize(Time.parse(string, DATE_FORMAT, TIMEZONE))
    end
  end

  def initialize(@days : Int32)
    raise ArgumentError.new("Invalid DuckDB date sentinel") if @days == Int32::MIN
  end

  def year : Int32
    parts.year
  end

  def month : Int32
    parts.month.to_i32
  end

  def day : Int32
    parts.day.to_i32
  end

  def infinite? : Bool
    @days == Int32::MAX || @days == -Int32::MAX
  end

  def_equals_and_hash @days

  def to_s(io : IO) : Nil
    if infinite?
      io << (@days > 0 ? "infinity" : "-infinity")
    else
      self.class.format(io, @days.to_i128)
    end
  end

  def to_time : Time
    date = parts
    unless 1 <= date.year <= 9999
      raise Exception.new("Date is outside Crystal Time's year range: #{date.year}")
    end
    Time.utc(date.year, date.month, date.day)
  end

  # :nodoc:
  def to_unsafe
    LibDuckDB::Date.new(days: @days)
  end

  # Proleptic Gregorian calendar, using eras to keep the full TIMESTAMP_S
  # range representable as well as DATE. Year zero is 1 BC in DuckDB text.
  # :nodoc:
  def self.calendar(days : Int128) : Tuple(Int64, Int32, Int32)
    z = days + 719468
    era = z // 146097
    doe = z - era * 146097
    yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
    year = yoe + era * 400
    doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
    mp = (5 * doy + 2) // 153
    day = doy - (153 * mp + 2) // 5 + 1
    month = mp + (mp < 10 ? 3 : -9)
    year += 1 if month <= 2
    {year.to_i64, month.to_i32, day.to_i32}
  end

  # :nodoc:
  def self.format(io : IO, days : Int128, suffix = true) : Bool
    year, month, day = calendar(days)
    bc = year <= 0
    io << (bc ? 1_i64 - year : year).to_s.rjust(4, '0') << '-' << month.to_s.rjust(2, '0') << '-' << day.to_s.rjust(2, '0')
    io << " (BC)" if bc && suffix
    bc
  end

  private def parts : LibDuckDB::DateParts
    raise Exception.new("Cannot convert an infinite DuckDB date to calendar fields or Time") if infinite?
    LibDuckDB.from_date(to_unsafe)
  end
end
