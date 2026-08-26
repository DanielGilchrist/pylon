require "kebab"
require "./cli/serve"
require "./cli/local"
require "./cli/sync"

@[Kebab::Command(name: "pylon", summary: "Two way file sync between a laptop and a dev box")]
struct Pylon::CLI
  include Kebab::Parseable

  @[Kebab::Subcommand]
  getter command : Serve | Local | Sync
end
