require "./pylon/cli"

exit(1) unless Pylon::CLI.run(ARGV)
