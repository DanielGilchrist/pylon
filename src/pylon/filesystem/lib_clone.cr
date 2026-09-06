Pylon::Platform.skip_file_unless :macos

lib LibClone
  NOFOLLOW = 0x0001_u32

  fun clonefile(source : UInt8*, destination : UInt8*, flags : UInt32) : Int32
end
