require "kebab"
require "./cli/remote"
require "./cli/sync"

@[Kebab::Command(name: "pylon", summary: "Two way file sync between a local and a remote directory")]
struct Pylon::CLI
  include Kebab::Parseable

  @[Kebab::Subcommand]
  getter command : Remote | Sync
end
