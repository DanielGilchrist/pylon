require "./pylon/cli/root"

exit(1) unless Pylon::CLI::Root.run(ARGV)
