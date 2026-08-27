require "../core/change"
require "../write/writer"

module Pylon::Session
  module Outcomes
    extend self

    # What a write actually did, as changes. Both ends apply these to their
    # own copy of the remote tree so the next delta has a shared baseline.
    def changes(outcomes : Array(Write::Outcome)) : Array(Core::Change)
      outcomes.map { |outcome| Core::Change.new(outcome.path, nil, outcome.entry) }
    end
  end
end
