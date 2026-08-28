require "../core/change"
require "../core/entry"

module Pylon::Write
  enum Skipped
    ModificationDetected
    UnknownState
    StagedContentMissing
    DryRun

    def explain : String
      case self
      in .modification_detected?  then "modification detected"
      in .unknown_state?          then "unknown state"
      in .staged_content_missing? then "staged content missing"
      in .dry_run?                then "dry run"
      end
    end
  end

  record Outcome,
    path : String,
    entry : Core::Entry?,
    skipped : Skipped? = nil do
    # Both ends apply these to their own copy of the remote tree so the next
    # delta has a shared baseline.
    def self.changes(outcomes : Array(Outcome)) : Array(Core::Change)
      outcomes.map { |outcome| Core::Change.new(outcome.path, nil, outcome.entry) }
    end

    def applied? : Bool
      skipped.nil?
    end

    def skipped? : Bool
      !skipped.nil?
    end
  end
end
