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
  scale, suffix = unit_for(Math.max(used, budget.to_u64))

  used.should be < budget,
    "#{what} allocated #{in_unit(used, scale, suffix)}, budget was #{in_unit(budget, scale, suffix)}"
end

def unit_for(bytes : Int) : {UInt64, String}
  return {MIB, "MiB"} if bytes >= MIB
  return {KIB, "KiB"} if bytes >= KIB

  {1_u64, "B"}
end

def in_unit(bytes : Int, scale : UInt64, suffix : String) : String
  return "#{bytes} #{suffix}" if scale == 1

  "#{(bytes / scale).round(1)} #{suffix}"
end
