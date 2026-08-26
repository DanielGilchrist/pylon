require "kebab"
require "./cli/serve"
require "./cli/local"
require "./cli/sync"

module Pylon::CLI
  @[Kebab::Command(name: "pylon", summary: "Two way file sync between a laptop and a dev box")]
  struct Root
    include Kebab::Parseable

    @[Kebab::Subcommand]
    getter command : Serve | Local | Sync
  end

  def self.run(args : Array(String)) : Bool
    Root.run(args)
  end
end
