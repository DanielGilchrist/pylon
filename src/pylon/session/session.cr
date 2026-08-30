require "../core"
require "../fibers"
require "./fault"
require "./progress"
require "./report"
require "../core/digests"
require "../write/writer"
require "./pending_write"

module Pylon::Session
  class Session(A, B)
    TRANSFER_BUDGET    = 32_u64 * 1024 * 1024
    WRITE_WINDOW       =   2
    PROGRESS_THRESHOLD = 200

    getter base : Core::Entry?

    def initialize(
      @local : A,
      @remote : B,
      @preferences : Core::Preferences = Core::Preferences.none,
      @base : Core::Entry? = nil,
      @dry_run : Bool = false,
      @push_first : Bool = false,
      @on_progress : Proc(Progress, Nil)? = nil,
    )
    end

    def cycle(now_ns : Int64) : Report | Fault
      started = Time.instant

      local_pending = Fibers.future { @local.scan(now_ns) }
      remote_pending = Fibers.future { @remote.scan(now_ns) }
      local_snapshot = Fibers.await(local_pending)
      remote_snapshot = Fibers.await(remote_pending)

      return local_snapshot if local_snapshot.is_a?(Fault)
      return remote_snapshot if remote_snapshot.is_a?(Fault)

      scanned = Time.instant

      # With no saved state the local side is the source of truth: adopting
      # the remote tree as the base makes this first cycle push only.
      if @push_first
        @base = remote_snapshot.root if @base.nil?
        @push_first = false
      end

      reconciliation = Core::Reconciler.reconcile(
        @base,
        local_snapshot.root,
        remote_snapshot.root,
        @preferences,
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
          reconciliation.troubles,
        )
      end

      local_changes = Core::Change.expand(reconciliation.local_changes)
      remote_changes = Core::Change.expand(reconciliation.remote_changes)

      if @dry_run
        return Report.new(
          reconciliation.conflicts,
          local_changes.map { |change| Write::Outcome.new(change.path, change.new, :dry_run) },
          remote_changes.map { |change| Write::Outcome.new(change.path, change.new, :dry_run) },
          troubles: reconciliation.troubles,
        )
      end

      fetched = Time.instant

      local_outcomes = ship(local_changes, @remote, @local, :to_local)
      return local_outcomes if local_outcomes.is_a?(Fault)

      remote_outcomes = ship(remote_changes, @local, @remote, :to_remote)
      return remote_outcomes if remote_outcomes.is_a?(Fault)

      written = Time.instant
      commit(Core::Change.expand(reconciliation.base_changes), local_outcomes, remote_outcomes)

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

      Report.new(reconciliation.conflicts, local_outcomes, remote_outcomes, troubles: reconciliation.troubles)
    end

    private def ship(changes : Array(Core::Change), source, target, direction : Direction) : Array(Write::Outcome) | Fault
      outcomes = [] of Write::Outcome
      total = changes.size
      pending = changes
      inflight = Deque(PendingWrite).new(WRITE_WINDOW)
      total_bytes = source.payload_size(changes)

      notify(direction, outcomes, total, total_bytes)

      until pending.empty?
        wanted = Core::Digests.required(pending)
        provided = source.content_source(wanted, TRANSFER_BUDGET)
        return provided if provided.is_a?(Fault)

        batch, pending = split(pending, provided.digests)

        break if batch.empty?

        inflight.push(target.write_begin(batch, provided))

        if inflight.size == WRITE_WINDOW && (oldest = inflight.shift?)
          written = oldest.await
          return written if written.is_a?(Fault)

          outcomes.concat(written)
          notify(direction, outcomes, total, total_bytes)
        end
      end

      while (oldest = inflight.shift?)
        written = oldest.await
        return written if written.is_a?(Fault)

        outcomes.concat(written)
        notify(direction, outcomes, total, total_bytes)
      end

      outcomes
    end

    private def notify(direction : Direction, outcomes : Array(Write::Outcome), total : Int32, total_bytes : UInt64?) : Nil
      return if total <= PROGRESS_THRESHOLD

      @on_progress.try(&.call(Progress.new(direction, outcomes.size, total, total_bytes)))
    end

    private def split(changes : Array(Core::Change), available : Set(Bytes)) : {Array(Core::Change), Array(Core::Change)}
      taken = 0

      changes.each do |change|
        entry = change.new
        digest = entry.is_a?(Core::File) ? entry.digest : nil

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

      @base = Core::Applier.apply(@base, changes).try(&.synchronizable)
    end
  end
end
