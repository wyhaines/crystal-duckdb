require "db"
require "uuid"
require "./duckdb/appender"
require "./duckdb/big_num"
require "./duckdb/column_reader"
require "./duckdb/chunk_view"
require "./duckdb/connection"
require "./duckdb/data_chunk"
require "./duckdb/database"
require "./duckdb/date"
require "./duckdb/decimal"
require "./duckdb/driver"
require "./duckdb/exception"
require "./duckdb/huge_int_helper"
require "./duckdb/interval"
require "./duckdb/libduckdb"
require "./duckdb/pooled_database"
require "./duckdb/result_set"
require "./duckdb/statement"
require "./duckdb/time_of_day"
require "./duckdb/time_tz"
require "./duckdb/timestamp"
require "./duckdb/unprepared_statement"
require "./duckdb/vector"
require "./duckdb/vector_view"
require "./duckdb/version"

module DuckDB
  IN_MEMORY = "duckdb://%3Amemory%3A"

  DATE_FORMAT = "%Y-%m-%d"

  TIME_OF_DAY_FORMAT_SUBSECOND = "%H:%M:%S.%6N"
  TIME_OF_DAY_FORMAT_SECOND    = "%H:%M:%S"

  TIMESTAMP_FORMAT_SUBSECOND = "#{DATE_FORMAT} #{TIME_OF_DAY_FORMAT_SUBSECOND}"
  TIMESTAMP_FORMAT_SECOND    = "#{DATE_FORMAT} #{TIME_OF_DAY_FORMAT_SECOND}"

  TIMEZONE = Time::Location::UTC

  # Public SQL type identifiers, shared with the C API.
  alias Type = LibDuckDB::Type

  alias Scalar = Nil | Bool | Int8 | Int16 | Int32 | Int64 | Int128 | UInt8 | UInt16 | UInt32 | UInt64 | UInt128 | Float32 | Float64 | String | Bytes | UUID | Decimal | Date | TimeOfDay | TimeTZ | Timestamp | Interval | BigNum
  alias Value = Scalar | Array(Value) | Hash(String, Value) | Hash(Value, Value)
  # Bindable scalar values used by crystal-db's shared driver specs. Nested
  # containers are read values; they are not prepared-statement parameters.
  alias Any = Scalar | ::Time
end
