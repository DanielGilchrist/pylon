module Pylon
  # shard.yml is the single source of truth. `script/release` bumps it, the tag
  # follows it, and the release workflow refuses a tag that disagrees.
  VERSION = {{ `shards version #{__DIR__}`.chomp.stringify }}
end
