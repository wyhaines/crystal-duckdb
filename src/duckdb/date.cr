struct DuckDB::Date
  # Preserve DuckDB's full date range, including infinities and BC dates.
  getter days : Int32

  def initialize(year : Int32, month : Int32, day : Int32)
    unless 1 <= year <= 9999 &&
           1 <= month <= 12 &&
           1 <= day <= Time.days_in_month(year, month)
      raise ArgumentError.new "Invalid date"
    end
    @days = (Time.utc(year, month, day) - Time::UNIX_EPOCH).days.to_i32
  end

  def initialize(time : Time)
    initialize(time.year, time.month, time.day)
  end

  def initialize(string : String)
    initialize(Time.parse(string, DATE_FORMAT, TIMEZONE))
  end

  def initialize(@days : Int32)
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

  def ==(other : self) : Bool
    @days == other.days
  end

  def to_s
    return "infinity" if @days == Int32::MAX
    return "-infinity" if @days == -Int32::MAX
    date = parts
    "#{date.year}-#{sprintf("%02d-%02d", date.month, date.day)}"
  end

  # Returns a Time only when the conversion is representable without clamping.
  def to_time
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

  private def parts : LibDuckDB::DateParts
    if @days == Int32::MAX || @days == -Int32::MAX
      raise Exception.new("Cannot convert an infinite DuckDB date to calendar fields or Time")
    end
    LibDuckDB.from_date(to_unsafe)
  end
end
