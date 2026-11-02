require "../spec_helper"

describe DuckDB::LibDuckDB::Type do
  it "matches every duckdb_type value through TIMESTAMP_TZ_NS" do
    names = %w(INVALID BOOLEAN TINYINT SMALLINT INTEGER BIGINT UTINYINT USMALLINT UINTEGER UBIGINT FLOAT DOUBLE TIMESTAMP DATE TIME INTERVAL HUGEINT VARCHAR BLOB DECIMAL TIMESTAMP_S TIMESTAMP_MS TIMESTAMP_NS ENUM LIST STRUCT MAP UUID UNION BIT TIME_TZ TIMESTAMP_TZ UHUGEINT ARRAY ANY BIGNUM SQLNULL STRING_LITERAL INTEGER_LITERAL TIME_NS GEOMETRY VARIANT TIMESTAMP_TZ_NS)
    DuckDB::LibDuckDB::Type.names.should eq(names)
    DuckDB::LibDuckDB::Type.values.map(&.value).should eq((0..42).to_a)
  end
end

describe "DuckDB prepared statement ABI" do
  it "returns the parameter count directly" do
    with_cnn do |cnn|
      statement = cnn.prepared("SELECT ?, ?").as(DuckDB::Statement)
      DuckDB::LibDuckDB.nparams(statement).should eq(2)
    end
  end
end
