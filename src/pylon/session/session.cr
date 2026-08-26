require "wait_group"
require "../core"
require "./report"
require "../core/digests"
require "../write/writer"

module Pylon::Session
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
      local_snapshot = uninitialized Scan::Snapshot
      remote_snapshot = uninitialized Scan::Snapshot

      WaitGroup.wait do |waiting|
        waiting.spawn { local_snapshot = @local.scan(now_ns) }
        waiting.spawn { remote_snapshot = @remote.scan(now_ns) }
      end

      reconciliation = Core::Reconciler.reconcile(
        @base,
        local_snapshot.root,
        remote_snapshot.root,
        @mode,
      )

      halt = Core::Safety.check(
        @base,
        local_snapshot.root,
        remote_snapshot.root,
        reconciliation.local_changes + reconciliation.remote_changes,
      )

      if halt
        return Report.new(
          reconciliation.conflicts,
          [] of Write::Outcome,
          [] of Write::Outcome,
          halt,
        )
      end

      local_contents = @remote.contents(Core::Digests.required(reconciliation.local_changes))
      remote_contents = @local.contents(Core::Digests.required(reconciliation.remote_changes))

      local_outcomes = @local.write(reconciliation.local_changes, local_contents)
      remote_outcomes = @remote.write(reconciliation.remote_changes, remote_contents)

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
