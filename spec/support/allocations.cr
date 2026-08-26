KIB = 1024_u64
MIB = 1024_u64 * KIB

def allocations(&) : UInt64
  GC.collect
  before = GC.stats.total_bytes
  yield
  GC.stats.total_bytes - before
end

def assert_allocates_under(budget : Int, what : String, &) : Nil
  used = allocations { yield }

  used.should be < budget,
    "#{what} allocated #{humanise(used)}, budget was #{humanise(budget.to_u64)}"
end

def humanise(bytes : Int) : String
  return "#{bytes} B" if bytes < KIB
  return "#{(bytes / KIB).round(1)} KiB" if bytes < MIB

  "#{(bytes / MIB).round(1)} MiB"
end
