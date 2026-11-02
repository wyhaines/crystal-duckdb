# Optional GMP-backed conversions. Requiring duckdb alone never loads big.
require "../duckdb"
require "big"

struct DuckDB::Decimal
  def to_big_d : BigDecimal
    BigDecimal.new(@value, @scale)
  end
end

struct DuckDB::BigNum
  def to_big_i : BigInt
    BigInt.new(to_s)
  end
end
