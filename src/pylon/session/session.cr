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

    # The signature lets us diff against the receiver's copy and send a patch instead
    # of the whole file. To do this we need to perform a round trip. For smaller batches
    # the round trip ends up costing more than sending the whole batch anyway so we don't
    # bother if the batch is under a certain size.
    DELTA_WAIT_BYTES = 256_u64 * 1024

    getter base : Core::Entry?

    def initialize(
      @local : A,
      @remote : B,
      @preferences : Core::Preferences = Core::Preferences.none,
      @base : Core::Entry? = nil,
      @dry_run : Bool = false,
      @push_first : Bool = false,
      @on_progress : Proc(Progress, Nil)? = nil,
    ) : Nil
    end

    def cycle(now_ns : Int64) : Report | Fault
      {% if flag?(:timing) %}
        started = Time.instant
        alloc_started = GC.stats.total_bytes
      {% end %}

      local_pending = Fibers.future { @local.scan(now_ns) }
      remote_pending = Fibers.future { @remote.scan(now_ns) }
      local_root = Fibers.await(local_pending)
      remote_root = Fibers.await(remote_pending)

      return local_root if local_root.is_a?(Fault)
      return remote_root if remote_root.is_a?(Fault)

      {% if flag?(:timing) %}
        scanned = Time.instant
        alloc_scanned = GC.stats.total_bytes
      {% end %}

      # With no saved state the local side is the source of truth: adopting
      # the remote tree as the base makes this first cycle push only.
      if @push_first
        @base = remote_root if @base.nil?
        @push_first = false
      end

      reconciliation = Core::Reconciler.reconcile(@base, local_root, remote_root, @preferences)

      {% if flag?(:timing) %}
        reconciled = Time.instant
        alloc_reconciled = GC.stats.total_bytes
      {% end %}

      halt = Core::Safety.check(reconciliation.local_changes + reconciliation.remote_changes)

      if halt
        return Report.new(
          reconciliation.conflicts,
          Array(Write::Outcome).new,
          Array(Write::Outcome).new,
          halt,
          reconciliation.troubles,
        )
      end

      local_changes = Core::Changes.expand(reconciliation.local_changes)
      remote_changes = Core::Changes.expand(reconciliation.remote_changes)

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

      local_holds = digests_present_in(local_root, local_changes)
      local_outcomes = transfer(local_changes, @remote, @local, :to_local, local_holds)
      return local_outcomes if local_outcomes.is_a?(Fault)

      remote_holds = digests_present_in(remote_root, remote_changes)
      remote_outcomes = transfer(remote_changes, @local, @remote, :to_remote, remote_holds)
      return remote_outcomes if remote_outcomes.is_a?(Fault)

      {% if flag?(:timing) %}
        written = Time.instant
        alloc_written = GC.stats.total_bytes
      {% end %}

      commit!(Core::Changes.expand(reconciliation.base_changes), local_outcomes, remote_outcomes)

      {% if flag?(:timing) %}
        STDERR.puts("  client scans=%.1f reconcile=%.1f contents=%.1f write=%.1f commit=%.1f" % [
          (scanned - started).total_milliseconds,
          (reconciled - scanned).total_milliseconds,
          (fetched - reconciled).total_milliseconds,
          (written - fetched).total_milliseconds,
          (Time.instant - written).total_milliseconds,
        ])
        STDERR.puts("  client alloc scans=%.1f reconcile=%.1f transfer=%.1f commit=%.1f MiB" % [
          (alloc_scanned - alloc_started) / 1_048_576.0,
          (alloc_reconciled - alloc_scanned) / 1_048_576.0,
          (alloc_written - alloc_reconciled) / 1_048_576.0,
          (GC.stats.total_bytes - alloc_written) / 1_048_576.0,
        ])
        {% if B.has_method?(:exchanges) %}
          STDERR.puts("  round trips so far=#{@remote.exchanges}")
        {% end %}
      {% end %}

      Report.new(reconciliation.conflicts, local_outcomes, remote_outcomes, troubles: reconciliation.troubles)
    end

    private def digests_present_in(root : Core::Entry?, changes : Core::Changes) : Set(Bytes)
      return Set(Bytes).new if changes.empty?

      holds = Core::Digests.all(root)
      changes.subtract_case_collision_digests(holds)
      holds
    end

    private def transfer(changes : Core::Changes, source : A | B, target : A | B, direction : Direction, target_holds : Set(Bytes)) : Array(Write::Outcome) | Fault
      total = changes.size
      outcomes = Array(Write::Outcome).new(total)
      offset = 0
      inflight = Deque(PendingWrite).new(WRITE_WINDOW)
      total_bytes = source.payload_size(changes)
      collector = Core::Digests::Collector.new
      signatures = Wire::Delta::Signatures.new
      candidates = Set(Bytes).new
      pending_signatures = nil

      if source.delta_capable? || target.delta_capable?
        pairs = delta_pairs(changes, source, target_holds, candidates)
        pending_signatures = target.signatures_begin(pairs) unless pairs.empty?
      end

      changes = changes.deletes_last(candidates)

      reused = 0

      {% if flag?(:timing) %}
        Wire::Delta.reset_tallies
      {% end %}

      notify(direction, outcomes, total, total_bytes)

      while offset < changes.size
        if source.delta_capable? && pending_signatures && (fault = pending_signatures.settle_into(signatures))
          return fault
        end

        wanted = collector.required(changes, offset)
        {% if flag?(:timing) %}
          before_reject = wanted.size
        {% end %}

        wanted.reject! { |digest| target_holds.includes?(digest) }

        {% if flag?(:timing) %}
          reused += before_reject - wanted.size
        {% end %}

        provided = source.content_source(wanted, TRANSFER_BUDGET, signatures)
        return provided if provided.is_a?(Fault)

        taken = split(changes, offset, provided.digests, target_holds)

        if taken.zero?
          changes.each(within: offset...) { |change| outcomes << Write::Outcome.new(change.path, change.old, Write::StagedContentMissing.new) }
          break
        end

        batch = changes.batch(offset, taken)
        offset += taken

        if pending_signatures && worth_waiting_for_signature?(batch, source, candidates) && (fault = pending_signatures.settle_into(signatures))
          return fault
        end

        inflight.push(target.write_begin(batch, provided))

        if inflight.size == WRITE_WINDOW && (oldest = inflight.shift?)
          if pending_signatures && (fault = pending_signatures.settle_into(signatures))
            return fault
          end

          written = oldest.await
          return written if written.is_a?(Fault)

          outcomes.concat(written)
          notify(direction, outcomes, total, total_bytes)
        end
      end

      if pending_signatures && (fault = pending_signatures.settle_into(signatures))
        return fault
      end

      while (oldest = inflight.shift?)
        written = oldest.await
        return written if written.is_a?(Fault)

        outcomes.concat(written)
        notify(direction, outcomes, total, total_bytes)
      end

      {% if flag?(:timing) %}
        if total > 0
          STDERR.puts("  transfer #{direction}: changes=#{total} reused=#{reused} candidates=#{candidates.size} signatures=#{signatures.size} deltas=#{Wire::Delta.deltas_sent} (#{(Wire::Delta.delta_bytes / 1_048_576.0).round(2)} MiB ops) fulls=#{Wire::Delta.fulls_sent} (#{(Wire::Delta.full_bytes / 1_048_576.0).round(2)} MiB raw)")
        end
      {% end %}

      outcomes
    end

    private def worth_waiting_for_signature?(batch : Core::Changes, source : A | B, candidates : Set(Bytes)) : Bool
      return false if candidates.empty?

      weight = 0_u64

      batch.each do |change|
        entry = change.new
        next unless entry.is_a?(Core::File) && candidates.includes?(entry.digest)

        size = source.known_size(change.path)
        return true if size.nil?

        weight += size
        return true if weight >= DELTA_WAIT_BYTES
      end

      false
    end

    private def notify(direction : Direction, outcomes : Array(Write::Outcome), total : Int32, total_bytes : UInt64?) : Nil
      return if total <= PROGRESS_THRESHOLD

      @on_progress.try(&.call(Progress.new(direction, outcomes.size, total, total_bytes)))
    end

    private def delta_pairs(
      changes : Core::Changes,
      source : A | B,
      target_holds : Set(Bytes),
      candidates : Set(Bytes),
    ) : Array(Wire::Message::SignaturesRequest::Pair)
      pairs = Array(Wire::Message::SignaturesRequest::Pair).new

      changes.each do |change|
        new = change.new
        old = change.old
        next unless new.is_a?(Core::File) && old.is_a?(Core::File)

        digest = new.digest
        next if old.digest == digest
        next if target_holds.includes?(digest)

        size = source.known_size(change.path)
        next if size && !Wire::Delta.worthwhile?(size)
        next unless candidates.add?(digest)

        pairs << Wire::Message::SignaturesRequest::Pair.new(digest, old.digest)
      end

      pairs
    end

    private def split(changes : Core::Changes, offset : Int32, available : Set(Bytes), target_holds : Set(Bytes)) : Int32
      taken = 0

      changes.each(within: offset...) do |change|
        entry = change.new
        digest = entry.is_a?(Core::File) ? entry.digest : nil

        break if digest && !available.includes?(digest) && !target_holds.includes?(digest)

        taken += 1
      end

      taken
    end

    private def commit!(
      planned : Core::Changes,
      local_outcomes : Array(Write::Outcome),
      remote_outcomes : Array(Write::Outcome),
    ) : Nil
      actual = Hash(String, Core::Entry?).new(initial_capacity: local_outcomes.size + remote_outcomes.size)
      local_outcomes.each { |outcome| actual[outcome.path] = outcome.entry }
      remote_outcomes.each { |outcome| actual[outcome.path] = outcome.entry }

      landed = Core::Changes.new(initial_capacity: planned.size)

      planned.each do |change|
        landed << if actual.has_key?(change.path)
          Core::Change.new(change.path, change.old, actual[change.path])
        else
          change
        end
      end

      @base = Core::Applier.apply(@base, landed).try(&.syncable)
    end
  end
end
