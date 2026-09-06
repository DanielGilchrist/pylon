module Pylon::Write
  alias Skipped = Skip | Problem

  enum Skip
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
    def self.changes(outcomes : Array(Outcome)) : Core::Changes
      changes = Core::Changes.new(initial_capacity: outcomes.size)
      outcomes.each { |outcome| changes << Core::Change.new(outcome.path, nil, outcome.entry) }
      changes
    end

    def applied? : Bool
      skipped.nil?
    end

    def explanation : String?
      case (skipped = @skipped)
      in Nil     then nil
      in Skip    then skipped.explain
      in Problem then skipped.reason
      end
    end
  end
end
