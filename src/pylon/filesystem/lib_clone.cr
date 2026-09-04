{% skip_file unless flag?(:darwin) %}

lib LibClone
  NOFOLLOW = 0x0001_u32

  fun clonefile(source : UInt8*, destination : UInt8*, flags : UInt32) : Int32
end
