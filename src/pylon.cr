require "./pylon/cli"

begin
  exit(1) unless Pylon::CLI.run(ARGV)
rescue error : IO::Error
  # a reader like `head` closing the pipe is not a failure
  raise error unless error.os_error == Errno::EPIPE

  exit(0)
end
