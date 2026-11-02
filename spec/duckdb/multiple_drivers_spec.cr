require "../spec_helper"

# Instantiate a second concrete driver so DB::Connection is no longer narrowed
# by the compiler to DuckDB::Connection at C call sites.
class OtherDriverConnection < DB::Connection
  def driver_name : String
    "other"
  end

  def build_prepared_statement(query) : DB::Statement
    raise "unused dummy driver"
  end

  def build_unprepared_statement(query) : DB::Statement
    raise "unused dummy driver"
  end
end

describe "DuckDB with another crystal-db driver" do
  it "can execute an unprepared query" do
    other = OtherDriverConnection.new(DB::Connection::Options.new)
    with_cnn do |cnn|
      cnn.unprepared.scalar("SELECT 42").should eq(42)
    end
    other.close
  end
end
