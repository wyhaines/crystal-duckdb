# :nodoc:
# crystal-db 0.13.1 through 0.15.0 publish a newly built resource as idle
# before its checkout reacquires the mutex. Reserve it for that checkout, and
# synchronize the collection accessors that upstream leaves unlocked.
class DuckDB::Pool < DB::Pool(DB::Connection)
  @closed = false

  def initialize(options : DB::Pool::Options, &factory : -> DB::Connection)
    super(options, &factory)
    # Closing a resource calls back into #delete, including during #release.
    @mutex = Mutex.new(protection: :reentrant)
  end

  private def build_resource : DB::Connection
    resource = @factory.call
    sync do
      if @closed
        resource.close
        raise Exception.new("Database pool is closed")
      end
      @total << resource
      # No checkouts exist during construction. After construction, @inflight
      # includes the checkout that owns this new resource until it returns.
      @idle << resource if @inflight == 0
    end
    resource
  end

  def close : Nil
    sync do
      return if @closed
      @closed = true
      error = nil
      @total.dup.each do |connection|
        begin
          connection.close
        rescue ex
          error ||= ex
        end
      end
      @total.clear
      @idle.clear
      raise error if error
    end
  end

  def stats
    sync { super }
  end

  def delete(resource : DB::Connection)
    sync { super }
  end

  def is_available?(resource : DB::Connection)
    sync { super }
  end
end
