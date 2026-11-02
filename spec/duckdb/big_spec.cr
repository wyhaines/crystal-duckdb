require "../spec_helper"
require "../../src/duckdb/big"

describe "DuckDB optional GMP conversions" do
  it "converts Decimal and BigNum exactly" do
    DuckDB::Decimal.new(-12345678901234567890123456789012345678_i128, 38, 19).to_big_d.should eq(BigDecimal.new("-1234567890123456789.0123456789012345678"))
    with_cnn do |cnn|
      text = "-" + "9" * 1000
      cnn.scalar("SELECT ?::BIGNUM", text).as(DuckDB::BigNum).to_big_i.should eq(BigInt.new(text))
    end
  end
end
