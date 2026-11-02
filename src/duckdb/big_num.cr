# An owned copy of DuckDB's BIGNUM vector bytes: a three-byte length/sign
# header followed by the big-endian magnitude, complemented for negatives.
struct DuckDB::BigNum
  @bytes : Bytes

  def initialize(bytes : Bytes)
    raise ArgumentError.new("Invalid BIGNUM bytes") if bytes.size < 4
    negative = bytes[0] & 0x80 == 0
    mask = negative ? 0xff : 0
    length = (((bytes[0].to_i32 ^ mask) & 0x7f) << 16) | ((bytes[1].to_i32 ^ mask) << 8) | (bytes[2].to_i32 ^ mask)
    raise ArgumentError.new("Invalid BIGNUM length") unless length == bytes.size - 3
    @bytes = bytes.dup
  end

  def bytes : Bytes
    @bytes.dup
  end

  def negative? : Bool
    @bytes[0] & 0x80 == 0
  end

  def_equals_and_hash @bytes

  # Base 256 -> base 10^9, using only bounded UInt64 arithmetic. No GMP.
  def to_s(io : IO) : Nil
    limbs = [0_u32]
    @bytes[3..].each do |byte|
      carry = (negative? ? ~byte : byte).to_u64
      limbs.size.times do |index|
        value = limbs[index].to_u64 * 256 + carry
        limbs[index] = (value % 1_000_000_000).to_u32
        carry = value // 1_000_000_000
      end
      limbs << carry.to_u32 unless carry == 0
    end
    io << '-' if negative? && !(limbs.size == 1 && limbs[0] == 0)
    io << limbs.last
    (limbs.size - 2).downto(0) { |index| io << limbs[index].to_s.rjust(9, '0') }
  end
end
