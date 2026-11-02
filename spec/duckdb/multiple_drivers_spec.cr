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

class OtherDriver < DB::Driver
  class ConnectionBuilder < DB::ConnectionBuilder
    def build : DB::Connection
      OtherDriverConnection.new(DB::Connection::Options.new)
    end
  end

  def connection_builder(uri : URI) : DB::ConnectionBuilder
    ConnectionBuilder.new
  end
end

DB.register_driver "other", OtherDriver

describe "DuckDB with another crystal-db driver" do
  it "preserves DB.open for other drivers" do
    DB.open "other://" do |db|
      db.using_connection { |cnn| cnn.driver_name.should eq("other") }
    end
  end

  it "can execute an unprepared query" do
    other = OtherDriverConnection.new(DB::Connection::Options.new)
    with_cnn do |cnn|
      cnn.unprepared.scalar("SELECT 42").should eq(42)
    end
    other.close
  end
end
