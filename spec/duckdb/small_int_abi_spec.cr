require "../spec_helper"

# Crystal passes 8- and 16-bit C arguments without sign or zero extension, which
# Apple arm64 requires (see LibDuckDB::CBoolArg). These values go through DuckDB's
# own conversions, which widen the register as received.
describe "DuckDB 8- and 16-bit C arguments" do
  it "binds extrema exactly, as scalars and as nested leaves" do
    with_cnn do |cnn|
      cnn.scalar("SELECT ?::BIGINT", Int8::MIN).should eq(-128_i64)
      cnn.scalar("SELECT ?::BIGINT", -1_i8).should eq(-1_i64)
      cnn.scalar("SELECT ?::BIGINT", Int16::MIN).should eq(-32768_i64)
      cnn.scalar("SELECT ?::BIGINT", UInt8::MAX).should eq(255_i64)
      cnn.scalar("SELECT ?::BIGINT", UInt16::MAX).should eq(65535_i64)
      cnn.scalar("SELECT ?::INTEGER", true).should eq(1)
      cnn.scalar("SELECT ?::INTEGER", false).should eq(0)
      cnn.scalar("SELECT ?::BIGINT[]", [Int8::MIN, -1_i8]).should eq([-128_i64, -1_i64])
      cnn.scalar("SELECT ?::BIGINT[]", [Int16::MIN, -2_i16]).should eq([-32768_i64, -2_i64])
    end
  end

  it "appends extrema exactly through DuckDB's conversions" do
    with_cnn do |cnn|
      cnn.exec "CREATE TABLE narrow (a TINYINT, b SMALLINT, c UTINYINT, d VARCHAR, e VARCHAR, f INTEGER)"
      cnn.appender("narrow") do |a|
        a.row { |r| r << -128_i16 << -32768_i32 << 255_u16 << -128_i8 << -32768_i16 << true }
      end
      cnn.query_one("SELECT a, b, c, d, e, f FROM narrow", as: {Int8, Int16, UInt8, String, String, Int32})
        .should eq({-128_i8, -32768_i16, 255_u8, "-128", "-32768", 1})
    end
  end
end
