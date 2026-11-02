require "../spec_helper"
require "log/spec"

# Instantiate a second concrete driver so DB::Connection is no longer narrowed
# by the compiler to DuckDB::Connection at C call sites.
class OtherDriverConnection < DB::Connection
  def driver_name : String
    "other"
  end

  def build_prepared_statement(query) : DB::Statement
    OtherDriverStatement.new(self, query)
  end

  def build_unprepared_statement(query) : DB::Statement
    raise "unused dummy driver"
  end
end

class OtherDriverStatement < DB::Statement
  protected def perform_exec(args : Enumerable) : DB::ExecResult
    DB::ExecResult.new(0_i64, 0_i64)
  end

  protected def perform_query(args : Enumerable) : DB::ResultSet
    raise "unused dummy query"
  end
end

# Original crystal-db 0.13.1/0.14.0/0.15.0 formatting, independent of the
# driver's replacement. Retain recursion here to compare nested Hash tuples too.
private module OriginalDBMetadata
  def self.arg_to_log(arg) : ::Log::Metadata::Value
    ::Log::Metadata::Value.new(arg.to_s)
  end

  def self.arg_to_log(arg : Enumerable) : ::Log::Metadata::Value
    ::Log::Metadata::Value.new(arg.to_a.map { |a| arg_to_log(a).as(::Log::Metadata::Value) })
  end

  def self.arg_to_log(arg : Int) : ::Log::Metadata::Value
    ::Log::Metadata::Value.new(arg.to_i64)
  end

  def self.arg_to_log(arg : String) : ::Log::Metadata::Value
    ::Log::Metadata::Value.new(arg)
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

  it "preserves crystal-db Array(Int32) and Hash(String, Int32) logging for another driver" do
    DB.connect "other://" do |cnn|
      values = [1, -2, 3]
      fields = {"one" => 1, "two" => -2}
      Log.capture(DB::Log.source) do |logs|
        cnn.exec("plain array", values)
        entry = logs.check(:debug, /Executing query/).entry
        entry.data[:args].should eq(OriginalDBMetadata.arg_to_log({values}))
        cnn.exec("plain hash", fields)
        entry = logs.check(:debug, /Executing query/).entry
        entry.data[:args].should eq(OriginalDBMetadata.arg_to_log({fields}))
      end
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
