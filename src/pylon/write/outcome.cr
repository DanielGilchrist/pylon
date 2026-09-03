require "../core/change"
require "../core/entry"

module Pylon::Write
  alias Skipped = ModificationDetected | UnknownState | StagedContentMissing | DryRun | WriteFailed

  record ModificationDetected do
    def explain : String
      "modification detected"
    end
  end

  record UnknownState do
    def explain : String
      "unknown state"
    end
  end

  record StagedContentMissing do
    def explain : String
      "staged content missing"
    end
  end

  record DryRun do
    def explain : String
      "dry run"
    end
  end

  record WriteFailed, reason : String do
    def explain : String
      reason
    end
  end

  record Outcome,
    path : String,
    entry : Core::Entry?,
    skipped : Skipped? = nil do
    # Both ends apply these to their own copy of the remote tree so the next
    # delta has a shared baseline.
    def self.changes(outcomes : Array(Outcome)) : Core::Changes
      changes = Core::Changes.new(initial_capacity: outcomes.size)
      outcomes.each { |outcome| changes << Core::Change.new(outcome.path, nil, outcome.entry) }
      changes
    end

    def applied? : Bool
      skipped.nil?
    end
  end
end
