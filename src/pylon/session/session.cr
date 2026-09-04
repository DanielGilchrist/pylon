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

    {% if flag?(:timing) %}
      @reused = 0
    {% end %}

    def initialize(
      @local : A,
      @remote : B,
      @preferences : Core::Preferences,
      @base : Core::Entry?,
      @dry_run : Bool,
      @push_first : Bool,
      @on_progress : Proc(Progress, Nil)?,
    ) : Nil
    end

    getter base : Core::Entry?

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

      if @push_first
        @base = remote_root
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
          reconciliation.troubles,
          halt,
        )
      end

      local_extraction = Core::Relocation.extract(reconciliation.local_changes)
      remote_extraction = Core::Relocation.extract(reconciliation.remote_changes)
      local_changes = Core::Changes.expand(local_extraction.changes)
      remote_changes = Core::Changes.expand(remote_extraction.changes)

      if @dry_run
        return Report.new(
          reconciliation.conflicts,
          local_changes.map { |change| Write::Outcome.new(change.path, change.new, Write::DryRun.new) },
          remote_changes.map { |change| Write::Outcome.new(change.path, change.new, Write::DryRun.new) },
          troubles: reconciliation.troubles,
          local_relocations: local_extraction.relocations,
          remote_relocations: remote_extraction.relocations,
        )
      end

      {% if flag?(:timing) %}
        fetched = Time.instant
      {% end %}

      local_holds = digests_present_in(local_root, local_changes)
      local_outcomes = transfer(local_changes, local_extraction.relocations, @remote, @local, :to_local, local_holds)
      return local_outcomes if local_outcomes.is_a?(Fault)

      remote_holds = digests_present_in(remote_root, remote_changes)
      remote_outcomes = transfer(remote_changes, remote_extraction.relocations, @local, @remote, :to_remote, remote_holds)
      return remote_outcomes if remote_outcomes.is_a?(Fault)

      {% if flag?(:timing) %}
        written = Time.instant
        alloc_written = GC.stats.total_bytes
      {% end %}

      commit!(reconciliation.base_changes, local_outcomes, remote_outcomes)

      {% if flag?(:timing) %}
        committed = Time.instant
      {% end %}

      @local.mirror(remote_root, remote_outcomes)

      {% if flag?(:timing) %}
        STDERR.puts("  client scans=%.1f reconcile=%.1f contents=%.1f write=%.1f commit=%.1f mirror=%.1f" % [
          (scanned - started).total_milliseconds,
          (reconciled - scanned).total_milliseconds,
          (fetched - reconciled).total_milliseconds,
          (written - fetched).total_milliseconds,
          (committed - written).total_milliseconds,
          (Time.instant - committed).total_milliseconds,
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

      Report.new(
        reconciliation.conflicts,
        local_outcomes,
        remote_outcomes,
        troubles: reconciliation.troubles,
        local_relocations: landed(local_extraction.relocations, local_outcomes),
        remote_relocations: landed(remote_extraction.relocations, remote_outcomes),
      )
    end

    private def landed(relocations : Array(Core::Relocation), outcomes : Array(Write::Outcome)) : Array(Core::Relocation)
      return relocations if relocations.empty?

      arrived = Set(String).new(initial_capacity: outcomes.size)
      outcomes.each { |outcome| arrived << outcome.path if outcome.applied? }

      relocations.select { |relocation| arrived.includes?(relocation.to) }
    end

    private def digests_present_in(root : Core::Entry?, changes : Core::Changes) : Set(Bytes)
      return Set(Bytes).new if changes.empty?

      holds = Core::Digests.all(root)
      changes.subtract_case_collision_digests(holds)
      holds
    end

    private def transfer(
      changes : Core::Changes,
      relocations : Array(Core::Relocation),
      source : A | B,
      target : A | B,
      direction : Direction,
      target_holds : Set(Bytes),
    ) : Array(Write::Outcome) | Fault
      total = changes.size + relocations.size * 2
      outcomes = Array(Write::Outcome).new(total)
      relocations_pending = !relocations.empty?
      none = Array(Core::Relocation).new
      offset = 0
      inflight = Deque(PendingWrite).new(WRITE_WINDOW)
      total_bytes = source.payload_size(changes)
      collector = Core::Digests::Collector.new
      signatures = Wire::Delta::Signatures.new
      bases = Wire::Prefixed::Bases.new
      candidates = Set(Bytes).new
      pending_signatures = nil

      if source.delta_capable? || target.delta_capable?
        pairs = delta_pairs(changes, source, target_holds, candidates, bases)
        pending_signatures = target.signatures_begin(pairs) unless pairs.empty?
      end

      if pending_signatures && source.delta_capable? && (fault = pending_signatures.settle_into(signatures))
        return fault
      end

      changes = changes.deletes_last(candidates)

      {% if flag?(:timing) %}
        @reused = 0
        Wire::Delta.reset_tallies
      {% end %}

      notify(direction, outcomes, total, total_bytes)

      pending_contents = source.content_begin(wanted_from(changes, offset, collector, target_holds), TRANSFER_BUDGET, signatures, bases)

      while offset < changes.size
        provided = pending_contents.await
        return provided if provided.is_a?(Fault)

        taken = split(changes, offset, provided.digests, target_holds)

        if taken.zero?
          changes.each(within: offset...) { |change| outcomes << Write::Outcome.new(change.path, change.old, Write::StagedContentMissing.new) }
          break
        end

        batch = changes.batch(offset, taken)
        offset += taken

        if offset < changes.size
          pending_contents = source.content_begin(wanted_from(changes, offset, collector, target_holds), TRANSFER_BUDGET, signatures, bases)
        end

        if pending_signatures && worth_waiting_for_signature?(batch, source, candidates) && (fault = pending_signatures.settle_into(signatures))
          return fault
        end

        if relocations_pending && offset == changes.size
          relocations_pending = false
          inflight.push(target.write_begin(batch, provided, relocations))
        else
          inflight.push(target.write_begin(batch, provided, none))
        end

        if inflight.size == WRITE_WINDOW && (oldest = inflight.shift?)
          written = oldest.await
          return written if written.is_a?(Fault)

          outcomes.concat(written)
          notify(direction, outcomes, total, total_bytes)
        end
      end

      if pending_signatures && (fault = pending_signatures.settle_into(signatures))
        return fault
      end

      if relocations_pending
        inflight.push(target.write_begin(Core::Changes.new, Wire::ContentSource::Materialised.new(Wire::Contents.new), relocations))
      end

      while (oldest = inflight.shift?)
        written = oldest.await
        return written if written.is_a?(Fault)

        outcomes.concat(written)
        notify(direction, outcomes, total, total_bytes)
      end

      {% if flag?(:timing) %}
        if total > 0
          STDERR.puts("  transfer %s: changes=%d reused=%d candidates=%d signatures=%d prefixed=%d (%.2f MiB frames) deltas=%d (%.2f MiB ops) fulls=%d (%.2f MiB raw)" % [
            direction,
            total,
            @reused,
            candidates.size,
            signatures.size,
            Wire::Delta.prefixed_sent,
            Wire::Delta.prefixed_bytes / 1_048_576.0,
            Wire::Delta.deltas_sent,
            Wire::Delta.delta_bytes / 1_048_576.0,
            Wire::Delta.fulls_sent,
            Wire::Delta.full_bytes / 1_048_576.0,
          ])
        end
      {% end %}

      outcomes
    end

    private def wanted_from(changes : Core::Changes, offset : Int32, collector : Core::Digests::Collector, target_holds : Set(Bytes)) : Array(Bytes)
      wanted = collector.required(changes, offset)

      {% if flag?(:timing) %}
        before_reject = wanted.size
      {% end %}

      wanted.reject! { |digest| target_holds.includes?(digest) }

      {% if flag?(:timing) %}
        @reused += before_reject - wanted.size
      {% end %}

      wanted
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
      bases : Wire::Prefixed::Bases,
    ) : Array(Wire::Message::SignaturesRequest::Pair)
      pairs = Array(Wire::Message::SignaturesRequest::Pair).new

      changes.each do |change|
        new = change.new
        old = change.old
        next unless new.is_a?(Core::File) && old.is_a?(Core::File)

        digest = new.digest
        next if old.digest == digest
        next if target_holds.includes?(digest)
        next if bases.has_key?(digest)

        size = source.known_size(change.path)
        next if size && !Wire::Prefixed.worthwhile?(size)

        bases[digest] = old.digest
        next if source.retained?(old.digest)
        next if size && !Wire::Delta.worthwhile?(size)

        candidates << digest
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
      landed = planned + Write::Outcome.changes(local_outcomes) + Write::Outcome.changes(remote_outcomes)

      @base = Core::Applier.apply(@base, landed).try(&.syncable)
    end
  end
end
