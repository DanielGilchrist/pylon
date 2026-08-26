require "./pylon/cli/commands"

exit(1) unless Pylon::CLI::Root.run(ARGV)
