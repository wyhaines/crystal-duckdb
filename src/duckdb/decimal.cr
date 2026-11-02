# An exact fixed-point value. Width and scale describe the DuckDB logical type.
struct DuckDB::Decimal
  include Comparable(Decimal)

  getter value : Int128
  getter width : UInt8
  getter scale : UInt8

  def initialize(@value : Int128, width : Int, scale : Int)
    unless 1 <= width <= 38 && 0 <= scale <= width && -(10_i128 ** width) < @value < 10_i128 ** width
      raise ArgumentError.new("Invalid DECIMAL value, width or scale")
    end
    @width = width.to_u8
    @scale = scale.to_u8
  end

  def <=>(other : self) : Int32
    left_whole, left_fraction = @value.divmod(10_i128 ** @scale)
    right_whole, right_fraction = other.value.divmod(10_i128 ** other.scale)
    whole = left_whole <=> right_whole
    return whole unless whole == 0
    scale = Math.max(@scale, other.scale)
    (left_fraction * 10_i128 ** (scale - @scale)) <=> (right_fraction * 10_i128 ** (scale - other.scale))
  end

  def hash(hasher)
    value, scale = @value, @scale
    while scale > 0 && value % 10 == 0
      value //= 10
      scale -= 1
    end
    scale.hash(value.hash(hasher))
  end

  def to_s(io : IO) : Nil
    io << '-' if @value < 0
    # DuckDB omits the integral zero when width equals scale.
    digits = @value.abs.to_s.rjust(@scale + (@width == @scale ? 0 : 1), '0')
    if @scale == 0
      io << digits
    else
      split = digits.bytesize - @scale
      io.write(digits.to_slice[0, split])
      io << '.'
      io.write(digits.to_slice[split, @scale])
    end
  end

  # Explicitly lossy; exact arithmetic remains available through duckdb/big.
  def to_f64 : Float64
    @value.to_f64 / 10_f64 ** @scale
  end

  # :nodoc:
  def to_unsafe
    LibDuckDB::Decimal.new(width: @width, scale: @scale, value: HugeIntHelper.i128_to_huge(@value))
  end
end
