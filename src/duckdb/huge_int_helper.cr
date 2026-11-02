module DuckDB
  module HugeIntHelper
    def self.huge_to_i128(value : LibDuckDB::HugeInt) : Int128
      (value.upper.to_i128 << 64) | value.lower.to_i128
    end

    def self.i128_to_huge(value : Int128) : LibDuckDB::HugeInt
      LibDuckDB::HugeInt.new(lower: value.to_u64!, upper: (value >> 64).to_i64)
    end

    def self.uhuge_to_u128(value : LibDuckDB::UHugeInt) : UInt128
      (value.upper.to_u128 << 64) | value.lower.to_u128
    end

    def self.u128_to_uhuge(value : UInt128) : LibDuckDB::UHugeInt
      LibDuckDB::UHugeInt.new(lower: value.to_u64!, upper: (value >> 64).to_u64)
    end
  end
end
