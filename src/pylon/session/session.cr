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
      {% if flag?(:timing) %}
        started = Time.instant
        alloc_started = GC.stats.total_bytes
      {% end %}

      local_pending = Fibers.future { @local.scan(now_ns) }
      remote_pending = Fibers.future { @remote.scan(now_ns) }
      local_snapshot = Fibers.await(local_pending)
      remote_snapshot = Fibers.await(remote_pending)

      return local_snapshot if local_snapshot.is_a?(Fault)
      return remote_snapshot if remote_snapshot.is_a?(Fault)

      {% if flag?(:timing) %}
        scanned = Time.instant
        alloc_scanned = GC.stats.total_bytes
      {% end %}

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

      {% if flag?(:timing) %}
        reconciled = Time.instant
        alloc_reconciled = GC.stats.total_bytes
      {% end %}

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
          local_changes.map { |change| Write::Outcome.new(change.path, change.new, Write::DryRun.new) },
          remote_changes.map { |change| Write::Outcome.new(change.path, change.new, Write::DryRun.new) },
          troubles: reconciliation.troubles,
        )
      end

      {% if flag?(:timing) %}
        fetched = Time.instant
      {% end %}

      local_outcomes = ship(local_changes, @remote, @local, :to_local)
      return local_outcomes if local_outcomes.is_a?(Fault)

      remote_outcomes = ship(remote_changes, @local, @remote, :to_remote)
      return remote_outcomes if remote_outcomes.is_a?(Fault)

      {% if flag?(:timing) %}
        written = Time.instant
        alloc_written = GC.stats.total_bytes
      {% end %}

      commit!(Core::Change.expand(reconciliation.base_changes), local_outcomes, remote_outcomes)

      {% if flag?(:timing) %}
        STDERR.puts("  client scans=%.1f reconcile=%.1f contents=%.1f write=%.1f commit=%.1f" % [
          (scanned - started).total_milliseconds,
          (reconciled - scanned).total_milliseconds,
          (fetched - reconciled).total_milliseconds,
          (written - fetched).total_milliseconds,
          (Time.instant - written).total_milliseconds,
        ])
        STDERR.puts("  client alloc scans=%.1f reconcile=%.1f ship=%.1f commit=%.1f MiB" % [
          (alloc_scanned - alloc_started) / 1048576.0,
          (alloc_reconciled - alloc_scanned) / 1048576.0,
          (alloc_written - alloc_reconciled) / 1048576.0,
          (GC.stats.total_bytes - alloc_written) / 1048576.0,
        ])
        {% if B.has_method?(:exchanges) %}
          STDERR.puts("  round trips so far=#{@remote.exchanges}")
        {% end %}
      {% end %}

      Report.new(reconciliation.conflicts, local_outcomes, remote_outcomes, troubles: reconciliation.troubles)
    end

    private def ship(changes : Array(Core::Change), source, target, direction : Direction) : Array(Write::Outcome) | Fault
      total = changes.size
      outcomes = Array(Write::Outcome).new(total)
      offset = 0
      inflight = Deque(PendingWrite).new(WRITE_WINDOW)
      total_bytes = source.payload_size(changes)
      collector = Core::Digests::Collector.new

      notify(direction, outcomes, total, total_bytes)

      while offset < changes.size
        wanted = collector.required(changes, offset)
        provided = source.content_source(wanted, TRANSFER_BUDGET)
        return provided if provided.is_a?(Fault)

        taken = split(changes, offset, provided.digests)

        if taken.zero?
          changes.each(within: offset...) { |change| outcomes << Write::Outcome.new(change.path, change.old, Write::StagedContentMissing.new) }
          break
        end

        batch = changes[offset, taken]
        offset += taken

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

    private def split(changes : Array(Core::Change), offset : Int32, available : Set(Bytes)) : Int32
      taken = 0

      changes.each(within: offset...) do |change|
        entry = change.new
        digest = entry.is_a?(Core::File) ? entry.digest : nil

        break if digest && !available.includes?(digest)

        taken += 1
      end

      taken
    end

    private def commit!(
      planned : Array(Core::Change),
      local_outcomes : Array(Write::Outcome),
      remote_outcomes : Array(Write::Outcome),
    ) : Nil
      actual = Hash(String, Core::Entry?).new(initial_capacity: local_outcomes.size + remote_outcomes.size)
      local_outcomes.each { |outcome| actual[outcome.path] = outcome.entry }
      remote_outcomes.each { |outcome| actual[outcome.path] = outcome.entry }

      planned.map! do |change|
        if actual.has_key?(change.path)
          Core::Change.new(change.path, change.old, actual[change.path])
        else
          change
        end
      end

      @base = Core::Applier.apply(@base, planned).try(&.syncable)
    end
  end
end
