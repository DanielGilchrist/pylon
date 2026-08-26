require "../scan/snapshot"

module Pylon::Session
  struct State
    getter base : Core::Entry?
    getter local_cache : Scan::Cache
    getter remote_cache : Scan::Cache

    def initialize(
      @base : Core::Entry? = nil,
      @local_cache : Scan::Cache = Scan::Cache.new,
      @remote_cache : Scan::Cache = Scan::Cache.new,
    )
    end
  end
end
