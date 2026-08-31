require "../core/change"
require "../fibers"
require "../core/paths"
require "../core/entry"
require "../scan/snapshot"
require "./guard"
require "./outcome"
require "./problem"

module Pylon::Write
  struct Writer(F, S)
    {% if flag?(:darwin) %}
      DEFAULT_PARALLELISM = 2
    {% else %}
      DEFAULT_PARALLELISM = System.cpu_count.to_i * 2
    {% end %}
    PARALLEL_THRESHOLD = 16

    def initialize(@filesystem : F, @staging : S, @cache : Scan::Cache, @parallelism : Int32 = DEFAULT_PARALLELISM)
    end

    def write(changes : Array(Core::Change)) : Array(Outcome)
      independent = independent_indices(changes)

      if @parallelism <= 1 || independent.size < PARALLEL_THRESHOLD
        return changes.map { |change| write_one(change) }
      end

      sequential = write_skipping(changes, independent)
      concurrent = write_concurrently(changes, independent)
      interleave(changes.size, independent, sequential, concurrent)
    end

    private def independent_indices(changes : Array(Core::Change)) : Array(Int32)
      indices = [] of Int32

      changes.each_with_index do |change, index|
        indices << index if independent?(change)
      end

      indices
    end

    private def independent?(change : Core::Change) : Bool
      new = change.new
      return false unless new.is_a?(Core::File)

      !clear_first?(change.old, new)
    end

    private def write_skipping(changes : Array(Core::Change), independent : Array(Int32)) : Array(Outcome)
      outcomes = Array(Outcome).new(changes.size - independent.size)
      skip = 0

      changes.each_with_index do |change, index|
        if skip < independent.size && independent[skip] == index
          skip += 1
          next
        end

        outcomes << write_one(change)
      end

      outcomes
    end

    private def write_concurrently(changes : Array(Core::Change), independent : Array(Int32)) : Array(Outcome)
      stripe = (independent.size + @parallelism - 1) // @parallelism
      groups = independent.each_slice(stripe).to_a
      slices = Array(Array(Outcome)).new(groups.size) { [] of Outcome }

      Fibers.parallel("write", groups.size) do |worker|
        write_group(changes, groups[worker], slices[worker])
      end

      collected = Array(Outcome).new(independent.size)
      slices.each { |slice| collected.concat(slice) }
      collected
    end

    private def write_group(changes : Array(Core::Change), indices : Array(Int32), into : Array(Outcome)) : Nil
      indices.each { |index| into << write_one(changes[index]) }
    end

    private def interleave(
      total : Int32,
      independent : Array(Int32),
      sequential : Array(Outcome),
      concurrent : Array(Outcome),
    ) : Array(Outcome)
      outcomes = Array(Outcome).new(total)
      concurrent_cursor = 0
      sequential_cursor = 0

      total.times do |index|
        if concurrent_cursor < independent.size && independent[concurrent_cursor] == index
          outcomes << concurrent[concurrent_cursor]
          concurrent_cursor += 1
        else
          outcomes << sequential[sequential_cursor]
          sequential_cursor += 1
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
      in Core::Directory                                                     then true
      in Core::File, Core::SymbolicLink, Core::Untracked, Core::Problematic then false
      end
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
