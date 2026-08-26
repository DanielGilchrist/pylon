require "kebab"
require "./server"
require "./local"
require "./sync"

module Pylon::CLI
  @[Kebab::Command(name: "pylon", summary: "Two way file sync between a laptop and a dev box")]
  struct Root
    include Kebab::Parseable

    @[Kebab::Subcommand]
    getter command : Serve | Local | Sync
  end
end
