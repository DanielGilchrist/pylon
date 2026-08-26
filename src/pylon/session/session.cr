require "../core/applier"
require "../core/reconciler"
require "../write/writer"

module Pylon::Session
  struct Report
    getter conflicts : Array(Core::Conflict)
    getter local_outcomes : Array(Write::Outcome)
    getter remote_outcomes : Array(Write::Outcome)

    def initialize(
      @conflicts : Array(Core::Conflict),
      @local_outcomes : Array(Write::Outcome),
      @remote_outcomes : Array(Write::Outcome),
    )
    end

    def skipped : Array(Write::Outcome)
      (local_outcomes + remote_outcomes).reject(&.applied?)
    end

    def quiet? : Bool
      conflicts.empty? && local_outcomes.empty? && remote_outcomes.empty?
    end
  end

  class Session(A, B)
    getter base : Core::Entry?

    def initialize(
      @local : A,
      @remote : B,
      @mode : Core::SyncMode = Core::SyncMode::TwoWaySafe,
      @base : Core::Entry? = nil,
    )
    end

    def cycle(now_ns : Int64) : Report
      local_snapshot = @local.scan(now_ns)
      remote_snapshot = @remote.scan(now_ns)

      reconciliation = Core::Reconciler.reconcile(
        @base,
        local_snapshot.root,
        remote_snapshot.root,
        @mode,
      )

      local_outcomes = @local.write(reconciliation.local_changes, @remote)
      remote_outcomes = @remote.write(reconciliation.remote_changes, @local)

      commit(reconciliation.base_changes, local_outcomes, remote_outcomes)

      Report.new(reconciliation.conflicts, local_outcomes, remote_outcomes)
    end

    private def commit(
      planned : Array(Core::Change),
      local_outcomes : Array(Write::Outcome),
      remote_outcomes : Array(Write::Outcome),
    ) : Nil
      actual = {} of String => Core::Entry?
      local_outcomes.each { |outcome| actual[outcome.path] = outcome.entry }
      remote_outcomes.each { |outcome| actual[outcome.path] = outcome.entry }

      changes = planned.map do |change|
        if actual.has_key?(change.path)
          Core::Change.new(change.path, change.old, actual[change.path])
        else
          change
        end
      end

      @base = Core::Entry.synchronizable(Core::Applier.apply(@base, changes))
    end
  end
end
