module Pylon::Session
  class Session(A, B, N)
    TRANSFER_BUDGET    = 32_u64 * 1024 * 1024
    WRITE_WINDOW       =   2
    PROGRESS_THRESHOLD = 200

    # The signature lets us diff against the receiver's copy and send a patch instead
    # of the whole file. To do this we need to perform a round trip. For smaller batches
    # the round trip ends up costing more than sending the whole batch anyway so we don't
    # bother if the batch is under a certain size.
    ROUND_TRIP_THRESHOLD_BYTES = 256_u64 * 1024

    alias PendingChecksums = Settled(Wire::Checksums::Map) |
                             Awaiting(Wire::Message::ChecksumsResponse, Wire::Checksums::Map)
    alias PendingReusable = Settled(Array(Bytes)) |
                            Awaiting(Wire::Message::ReusableResponse, Array(Bytes))
    alias PendingContents = Settled(Wire::ContentSource) |
                            Awaiting(Wire::Message::ContentsResponse, Wire::ContentSource)
    alias PendingOutcomes = Settled(Array(Write::Outcome)) |
                            Awaiting(Wire::Message::WriteResponse, Array(Write::Outcome))

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
      @narrator : N,
    ) : Nil
    end

    getter base : Core::Entry?
    getter local : A

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
      local_changes = Core::Changes.flatten(local_extraction.changes)
      remote_changes = Core::Changes.flatten(remote_extraction.changes)

      if @dry_run
        return Report.new(
          reconciliation.conflicts,
          local_changes.map { |change| preview(change) },
          remote_changes.map { |change| preview(change) },
          troubles: reconciliation.troubles,
          local_relocations: local_extraction.relocations,
          remote_relocations: remote_extraction.relocations,
        )
      end

      {% if flag?(:timing) %}
        fetched = Time.instant
      {% end %}

      local_reusable = reusable_in(local_root, local_changes)
      local_outcomes = transfer(
        local_changes,
        local_extraction.relocations,
        @remote,
        @local,
        :local,
        local_reusable,
      )
      return local_outcomes if local_outcomes.is_a?(Fault)

      remote_reusable = reusable_in(remote_root, remote_changes)
      remote_outcomes = transfer(
        remote_changes,
        remote_extraction.relocations,
        @local,
        @remote,
        :remote,
        remote_reusable,
      )
      return remote_outcomes if remote_outcomes.is_a?(Fault)

      {% if flag?(:timing) %}
        written = Time.instant
        alloc_written = GC.stats.total_bytes
      {% end %}

      commit!(reconciliation.base_changes, local_outcomes, remote_outcomes)

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

      Report.new(
        reconciliation.conflicts,
        local_outcomes,
        remote_outcomes,
        troubles: reconciliation.troubles,
        local_relocations: landed(local_extraction.relocations, local_outcomes),
        remote_relocations: landed(remote_extraction.relocations, remote_outcomes),
      )
    end

    private def preview(change : Core::Change) : Write::Outcome
      Write::Outcome.new(change.path, change.new, Write::Skip::DryRun)
    end

    private def landed(
      relocations : Array(Core::Relocation),
      outcomes : Array(Write::Outcome),
    ) : Array(Core::Relocation)
      return relocations if relocations.empty?

      arrived = Set(String).new(initial_capacity: outcomes.size)
      outcomes.each { |outcome| arrived << outcome.path if outcome.applied? }

      relocations.select { |relocation| arrived.includes?(relocation.to) }
    end

    private def reusable_in(root : Core::Entry?, changes : Core::Changes) : Set(Bytes)
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
      into : Replica,
      target_reusable : Set(Bytes),
    ) : Array(Write::Outcome) | Fault
      total = changes.size + relocations.size * 2
      outcomes = Array(Write::Outcome).new(total)
      relocations_pending = !relocations.empty?
      none = Array(Core::Relocation).new
      offset = 0
      inflight = Deque(PendingOutcomes).new(WRITE_WINDOW)
      total_bytes = source.total_size(changes)
      collector = Core::Digests::Collector.new
      checksums = Wire::Checksums::Map.new
      bases = Wire::Bases.new
      candidates = Set(Bytes).new
      pending_checksums = nil

      if source.remote? || target.remote?
        asked = bases_needing_checksums(changes, source, target_reusable, candidates, bases)
        pending_checksums = target.request_checksums(asked) unless asked.empty?
      end

      if pending_checksums && source.remote?
        if (fault = settle(pending_checksums, checksums))
          return fault
        end

        pending_checksums = nil
      end

      asked = worth_asking_about(changes, source, target_reusable, bases)

      case (held = target.request_reusable(asked).await)
      in Fault        then return held
      in Array(Bytes) then held.each { |digest| target_reusable << digest }
      end

      changes = changes.ordered_for_writing(candidates)

      {% if flag?(:timing) %}
        @reused = 0
        Wire::Splice.reset_tallies
      {% end %}

      notify(into, outcomes, total, total_bytes)

      pending_contents = source.request_content(
        digests_to_fetch(changes, offset, collector, target_reusable),
        TRANSFER_BUDGET,
        checksums,
        bases,
      )

      while offset < changes.size
        provided = pending_contents.await
        return provided if provided.is_a?(Fault)

        taken = writable_count(changes, offset, provided.digests, target_reusable)

        if taken.zero?
          changes.each(within: offset...) do |change|
            missing = Write::Skip::StagedContentMissing
            outcomes << Write::Outcome.new(change.path, change.old, missing)
          end
          break
        end

        batch = changes.batch(offset, taken)
        offset += taken

        if offset < changes.size
          pending_contents = source.request_content(
            digests_to_fetch(changes, offset, collector, target_reusable),
            TRANSFER_BUDGET,
            checksums,
            bases,
          )
        end

        if pending_checksums && worth_waiting_for_checksums?(batch, source, candidates)
          if (fault = settle(pending_checksums, checksums))
            return fault
          end

          pending_checksums = nil
        end

        if relocations_pending && offset == changes.size
          relocations_pending = false
          inflight.push(target.request_write(batch, provided, relocations))
        else
          inflight.push(target.request_write(batch, provided, none))
        end

        if inflight.size == WRITE_WINDOW && (oldest = inflight.shift?)
          written = oldest.await
          return written if written.is_a?(Fault)

          outcomes.concat(written)
          notify(into, outcomes, total, total_bytes)
        end
      end

      if pending_checksums && (fault = settle(pending_checksums, checksums))
        return fault
      end

      if relocations_pending
        nothing = Wire::ContentSource::Materialised.new(Wire::Contents.new)
        inflight.push(target.request_write(Core::Changes.new, nothing, relocations))
      end

      while (oldest = inflight.shift?)
        written = oldest.await
        return written if written.is_a?(Fault)

        outcomes.concat(written)
        notify(into, outcomes, total, total_bytes)
      end

      {% if flag?(:timing) %}
        if total > 0
          summary = "  transfer %s: changes=%d reused=%d candidates=%d checksums=%d " \
                    "dictionary=%d (%.2f MiB) spliced=%d (%.2f MiB ops) fulls=%d (%.2f MiB raw)"
          STDERR.puts(summary % [
            into,
            total,
            @reused,
            candidates.size,
            checksums.size,
            Wire::Splice.dictionaries_sent,
            Wire::Splice.dictionary_bytes / 1_048_576.0,
            Wire::Splice.splices_sent,
            Wire::Splice.splice_bytes / 1_048_576.0,
            Wire::Splice.fulls_sent,
            Wire::Splice.full_bytes / 1_048_576.0,
          ])
        end
      {% end %}

      outcomes
    end

    private def settle(pending : PendingChecksums, checksums : Wire::Checksums::Map) : Fault?
      received = pending.await
      return received if received.is_a?(Fault)

      checksums.merge!(received)
      nil
    end

    private def digests_to_fetch(
      changes : Core::Changes,
      offset : Int32,
      collector : Core::Digests::Collector,
      target_reusable : Set(Bytes),
    ) : Array(Bytes)
      wanted = collector.required(changes, offset)

      {% if flag?(:timing) %}
        before_reject = wanted.size
      {% end %}

      wanted.reject! { |digest| target_reusable.includes?(digest) }

      {% if flag?(:timing) %}
        @reused += before_reject - wanted.size
      {% end %}

      wanted
    end

    private def worth_asking_about(
      changes : Core::Changes,
      source : A | B,
      target_reusable : Set(Bytes),
      bases : Wire::Bases,
    ) : Array(Bytes)
      asked = Array(Bytes).new
      seen = Set(Bytes).new
      weight = 0_u64
      unsized = false

      changes.each do |change|
        entry = change.new
        next unless entry.is_a?(Core::File)

        digest = entry.digest
        next if target_reusable.includes?(digest)
        next if (base = bases[digest]?) && source.holds?(base)
        next unless seen.add?(digest)

        asked << digest
        size = source.size_of(change.path)
        unsized ||= size.nil?
        weight += size if size
      end

      unsized || weight >= ROUND_TRIP_THRESHOLD_BYTES ? asked : Array(Bytes).new
    end

    private def worth_waiting_for_checksums?(
      batch : Core::Changes,
      source : A | B,
      candidates : Set(Bytes),
    ) : Bool
      return false if candidates.empty?

      weight = 0_u64

      batch.each do |change|
        entry = change.new
        next unless entry.is_a?(Core::File) && candidates.includes?(entry.digest)

        size = source.size_of(change.path)
        return true if size.nil?

        weight += size
        return true if weight >= ROUND_TRIP_THRESHOLD_BYTES
      end

      false
    end

    private def notify(
      into : Replica,
      outcomes : Array(Write::Outcome),
      total : Int32,
      total_bytes : UInt64?,
    ) : Nil
      return if total <= PROGRESS_THRESHOLD

      @narrator.progress(TransferProgress.new(into, outcomes.size, total, total_bytes))
    end

    private def bases_needing_checksums(
      changes : Core::Changes,
      source : A | B,
      target_reusable : Set(Bytes),
      candidates : Set(Bytes),
      bases : Wire::Bases,
    ) : Wire::Bases
      asked = Wire::Bases.new

      changes.each do |change|
        new = change.new
        old = change.old
        next unless new.is_a?(Core::File) && old.is_a?(Core::File)

        digest = new.digest
        next if old.digest == digest
        next if target_reusable.includes?(digest)
        next if bases.has_key?(digest)

        size = source.size_of(change.path)
        next if size && !Wire::Dictionary.worthwhile?(size)

        bases[digest] = old.digest
        next if source.holds?(old.digest)
        next if size && !Wire::Splice.worthwhile?(size)

        candidates << digest
        asked[digest] = old.digest
      end

      asked
    end

    private def writable_count(
      changes : Core::Changes,
      offset : Int32,
      delivered : Set(Bytes),
      target_reusable : Set(Bytes),
    ) : Int32
      taken = 0

      changes.each(within: offset...) do |change|
        entry = change.new
        digest = entry.digest if entry.is_a?(Core::File)

        break if digest && !delivered.includes?(digest) && !target_reusable.includes?(digest)

        taken += 1
      end

      taken
    end

    private def commit!(
      planned : Core::Changes,
      local_outcomes : Array(Write::Outcome),
      remote_outcomes : Array(Write::Outcome),
    ) : Nil
      landed = planned + Write::Outcome.changes(local_outcomes)
      landed += Write::Outcome.changes(remote_outcomes)

      @base = Core::Applier.apply(@base, landed).try(&.syncable)
    end
  end
end
