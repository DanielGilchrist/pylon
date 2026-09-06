lib LibC
  fun geteuid : UInt32
end

# Root ignores the permission bits, so an example that needs a syscall to be denied would pass
# without proving anything. Examples that depend on being denied say so.
def running_as_root? : Bool
  LibC.geteuid == 0
end
