require "../core/change"
require "../fibers"
require "../core/paths"
require "../core/entry"
require "../missing"
require "../scan/ignores"
require "../scan/snapshot"
require "./grouping"
require "./guard"
require "./indexed_outcomes"
require "./outcome"
require "./problem"

module Pylon::Write
  struct Writer(F, S)
    # APFS contends on staged writes past ~4 workers, 2 was the measured as being the most optimal.
    # ext4 on Linux didn't seem to have the same problem so just leaving it to scale by CPU count for now.
    {% if flag?(:darwin) %}
      DEFAULT_PARALLELISM = 2
    {% else %}
      DEFAULT_PARALLELISM = System.cpu_count.to_i * 2
    {% end %}

    PARALLEL_THRESHOLD = 16

    def initialize(
      @filesystem : F,
      @staging : S,
      @cache : Scan::Cache,
      @ignores : Scan::Ignores = Scan::Ignores::NONE,
      @parallelism : Int32 = DEFAULT_PARALLELISM,
    )
    end

    def write(changes : Core::Changes) : Array(Outcome)
      grouping = Grouping.partition(changes) { |change| independent?(change) }

      if @parallelism <= 1 || grouping.independent.size < PARALLEL_THRESHOLD
        return changes.map { |change| write_one(change) }
      end

      sequential = write_group(changes, grouping.ordered)
      concurrent = write_concurrently(changes, grouping.independent)
      removed = write_group(changes, grouping.removals)

      assemble(
        changes.size,
        IndexedOutcomes.new(grouping.ordered, sequential),
        IndexedOutcomes.new(grouping.independent, concurrent),
        IndexedOutcomes.new(grouping.removals, removed),
      )
    end

    private def independent?(change : Core::Change) : Bool
      new = change.new
      return false unless new.is_a?(Core::File)

      !clear_first?(change.old, new)
    end

    private def write_group(changes : Core::Changes, indices : Array(Int32)) : Array(Outcome)
      outcomes = Array(Outcome).new(indices.size)
      indices.each { |index| outcomes << write_one(changes[index]) }
      outcomes
    end

    private def write_concurrently(changes : Core::Changes, independent : Array(Int32)) : Array(Outcome)
      stripe = (independent.size + @parallelism - 1) // @parallelism
      groups = independent.each_slice(stripe).to_a
      slices = Array(Array(Outcome)).new(groups.size) { [] of Outcome }

      Fibers.parallel(:write, groups.size) do |worker|
        groups[worker].each { |index| slices[worker] << write_one(changes[index]) }
      end

      collected = Array(Outcome).new(independent.size)
      slices.each { |slice| collected.concat(slice) }
      collected
    end

    private def assemble(total : Int32, *groups : IndexedOutcomes) : Array(Outcome)
      outcomes = Array(Outcome).new(total)

      total.times do |index|
        groups.each do |group|
          if (claimed = group.claim?(index))
            outcomes << claimed
            break
          end
        end
      end

      outcomes
    end

    private def write_one(change : Core::Change) : Outcome
      verdict = Guard.check(
        change.old,
        @cache[change.path]?,
        @filesystem.observe(change.path),
      )

      case verdict
      in .modification_detected?
        return Outcome.new(change.path, change.old, ModificationDetected.new)
      in .unknown_state?
        return Outcome.new(change.path, change.old, UnknownState.new)
      in .proceed?
      end

      if (swapped = swap_permissions(change))
        return swapped
      end

      if clear_first?(change.old, change.new)
        old = change.old

        if old.is_a?(Core::Directory)
          case guard_removal(change.path, old)
          in .modification_detected?
            return Outcome.new(change.path, change.old, ModificationDetected.new)
          in .unknown_state?
            return Outcome.new(change.path, change.old, UnknownState.new)
          in .proceed?
          end
        end

        if (blocked = @filesystem.remove(change.path))
          return Outcome.new(change.path, change.old, WriteFailed.new(blocked.reason))
        end
      end

      created = create(change.path, change.new)

      if created.is_a?(Problem)
        return Outcome.new(change.path, change.old, WriteFailed.new(created.reason))
      end

      return Outcome.new(change.path, created, StagedContentMissing.new) if incomplete?(change.new, created)

      Outcome.new(change.path, created)
    end

    private def clear_first?(old : Core::Entry?, new : Core::Entry?) : Bool
      return false if old.nil?
      return true if new.nil?

      directory?(old) || directory?(new)
    end

    private def directory?(entry : Core::Entry) : Bool
      case entry
      in Core::Directory                                                    then true
      in Core::File, Core::SymbolicLink, Core::Untracked, Core::Problematic then false
      end
    end

    private def guard_removal(path : String, expected : Core::Directory) : Verdict
      contents = expected.contents

      listed = @filesystem.each_child(path) do |name|
        child_path = Core::Paths.join(path, name)

        if (child = contents[name]?)
          verdict = guard_child(child_path, child)
          return verdict unless verdict.proceed?
        elsif !expendable?(child_path)
          return Verdict::ModificationDetected
        end
      end

      case listed
      in Missing, Nil then Verdict::Proceed
      in Problem      then Verdict::UnknownState
      end
    end

    private def guard_child(path : String, expected : Core::Entry) : Verdict
      observed = @filesystem.observe(path)
      return Verdict::Proceed if observed.nil?

      verdict = Guard.check(expected, @cache[path]?, observed)
      return verdict unless verdict.proceed?

      expected.is_a?(Core::Directory) ? guard_removal(path, expected) : verdict
    end

    private def expendable?(path : String) : Bool
      return true if @ignores.ignore?(path)

      @filesystem.observe(path).is_a?(Scan::ObservedUntracked)
    end

    private def swap_permissions(change : Core::Change) : Outcome?
      old = change.old
      new = change.new

      return unless old.is_a?(Core::File) && new.is_a?(Core::File)
      return unless old.digest == new.digest
      return if old.executable? == new.executable?

      return if @filesystem.set_executable(change.path, new.executable?)

      Outcome.new(change.path, new)
    end

    private def create(path : String, entry : Core::Entry?) : Core::Entry | Problem | Nil
      case entry
      in Nil, Core::Untracked, Core::Problematic
        nil
      in Core::Directory
        if (blocked = @filesystem.create_directory(path))
          return blocked
        end

        contents = {} of String => Core::Entry

        entry.contents.each do |name, child|
          created = create(Core::Paths.join(path, name), child)
          return created if created.is_a?(Problem)

          contents[name] = created if created
        end

        Core::Directory.new(contents)
      in Core::File
        content = @staging.content(entry.digest)
        return if content.nil?

        @filesystem.write_file(path, content, entry.executable?) || entry
      in Core::SymbolicLink
        @filesystem.create_symlink(path, entry.target) || entry
      end
    end

    private def incomplete?(intended : Core::Entry?, created : Core::Entry?) : Bool
      intended != created
    end
  end
end
