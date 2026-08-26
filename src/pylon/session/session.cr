require "wait_group"
require "../core"
require "./report"
require "../core/digests"
require "../write/writer"

module Pylon::Session
  class Session(A, B)
    TRANSFER_BUDGET = 32_u64 * 1024 * 1024

    getter base : Core::Entry?

    def initialize(
      @local : A,
      @remote : B,
      @mode : Core::SyncMode = Core::SyncMode::TwoWaySafe,
      @base : Core::Entry? = nil,
    )
    end

    def cycle(now_ns : Int64) : Report
      started = Time.instant
      local_snapshot = uninitialized Scan::Snapshot
      remote_snapshot = uninitialized Scan::Snapshot

      WaitGroup.wait do |waiting|
        waiting.spawn { local_snapshot = @local.scan(now_ns) }
        waiting.spawn { remote_snapshot = @remote.scan(now_ns) }
      end

      scanned = Time.instant

      reconciliation = Core::Reconciler.reconcile(
        @base,
        local_snapshot.root,
        remote_snapshot.root,
        @mode,
      )

      reconciled = Time.instant

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

      local_changes = Core::Changes.expand(reconciliation.local_changes)
      remote_changes = Core::Changes.expand(reconciliation.remote_changes)

      fetched = Time.instant

      local_outcomes = ship(local_changes, @remote, @local)
      remote_outcomes = ship(remote_changes, @local, @remote)

      written = Time.instant
      commit(Core::Changes.expand(reconciliation.base_changes), local_outcomes, remote_outcomes)

      if ENV["PYLON_TIMING"]?
        STDERR.puts("  client scans=%.1f reconcile=%.1f contents=%.1f write=%.1f commit=%.1f" % [
          (scanned - started).total_milliseconds,
          (reconciled - scanned).total_milliseconds,
          (fetched - reconciled).total_milliseconds,
          (written - fetched).total_milliseconds,
          (Time.instant - written).total_milliseconds,
        ])
        {% if B.has_method?(:exchanges) %}
          STDERR.puts("  round trips so far=#{@remote.exchanges}")
        {% end %}
      end

      Report.new(reconciliation.conflicts, local_outcomes, remote_outcomes)
    end

    private def ship(changes : Array(Core::Change), source, target) : Array(Write::Outcome)
      outcomes = [] of Write::Outcome

      pending = changes

      until pending.empty?
        wanted = Core::Digests.required(pending)
        provided = source.content_source(wanted, TRANSFER_BUDGET)
        batch, pending = split(pending, provided.digests)

        break if batch.empty?

        outcomes.concat(target.write(batch, provided))
      end

      outcomes
    end

    private def split(changes : Array(Core::Change), available : Set(Bytes)) : {Array(Core::Change), Array(Core::Change)}
      taken = 0

      changes.each do |change|
        entry = change.new
        digest = entry && entry.kind.file? ? entry.digest : nil

        break if digest && !available.includes?(digest)

        taken += 1
      end

      {changes[0, taken], changes[taken..]}
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
