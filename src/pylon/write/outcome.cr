require "../core/change"
require "../core/entry"

module Pylon::Write
  record Outcome,
    path : String,
    entry : Core::Entry?,
    problem : String? = nil do
    # Both ends apply these to their own copy of the remote tree so the next
    # delta has a shared baseline.
    def self.changes(outcomes : Array(Outcome)) : Array(Core::Change)
      outcomes.map { |outcome| Core::Change.new(outcome.path, nil, outcome.entry) }
    end

    def applied? : Bool
      problem.nil?
    end
  end
end
