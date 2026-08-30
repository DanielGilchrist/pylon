require "wait_group"
require "../core/change"
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
    PARALLEL_THRESHOLD  = 16

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
      return false if new.nil? || !new.kind.file?

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

      failure : Exception? = nil
      context = Fiber::ExecutionContext::Parallel.new("write", groups.size)
      waiting = WaitGroup.new(groups.size)

      groups.each_with_index do |group, worker|
        write_slice(context, waiting, changes, group, slices[worker]) do |error|
          failure ||= error
        end
      end

      waiting.wait

      if (write_failure = failure)
        raise write_failure
      end

      collected = Array(Outcome).new(independent.size)
      slices.each { |slice| collected.concat(slice) }
      collected
    end

    private def write_slice(
      context : Fiber::ExecutionContext::Parallel,
      waiting : WaitGroup,
      changes : Array(Core::Change),
      indices : Array(Int32),
      into : Array(Outcome),
      &on_error : Exception ->
    ) : Nil
      context.spawn do
        begin
          indices.each { |index| into << write_one(changes[index]) }
        rescue error
          on_error.call(error)
        ensure
          waiting.done
        end
      end
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
        @filesystem.metadata(change.path),
      )

      case verdict
      in .modification_detected?
        return Outcome.new(change.path, change.old, :modification_detected)
      in .unknown_state?
        return Outcome.new(change.path, change.old, :unknown_state)
      in .proceed?
      end

      if (swapped = swap_permissions(change))
        return swapped
      end

      if clear_first?(change.old, change.new)
        if (blocked = @filesystem.remove(change.path))
          return Outcome.new(change.path, change.old, :write_failed, blocked.reason)
        end
      end

      created = create(change.path, change.new)

      if created.is_a?(Problem)
        return Outcome.new(change.path, change.old, :write_failed, created.reason)
      end

      return Outcome.new(change.path, created, :staged_content_missing) if incomplete?(change.new, created)

      Outcome.new(change.path, created)
    end

    private def clear_first?(old : Core::Entry?, new : Core::Entry?) : Bool
      return false if old.nil?
      return true if new.nil?
      return true if old.kind.directory? || new.kind.directory?

      false
    end

    private def swap_permissions(change : Core::Change) : Outcome?
      old = change.old
      new = change.new

      return nil if old.nil? || new.nil?
      return nil unless old.kind.file? && new.kind.file?
      return nil unless old.digest == new.digest
      return nil if old.executable? == new.executable?

      return nil if @filesystem.set_executable(change.path, new.executable?)

      Outcome.new(change.path, new)
    end

    private def create(path : String, entry : Core::Entry?) : Core::Entry | Problem | Nil
      return nil if entry.nil?

      case entry.kind
      in .directory?
        if (blocked = @filesystem.create_directory(path))
          return blocked
        end

        contents = {} of String => Core::Entry

        entry.contents.each do |name, child|
          created = create(Core::Paths.join(path, name), child)
          return created if created.is_a?(Problem)

          contents[name] = created if created
        end

        Core::Entry.directory(contents)
      in .file?
        digest = entry.digest
        return nil if digest.nil?

        content = @staging.content(digest)
        return nil if content.nil?

        @filesystem.write_file(path, content, entry.executable?) || entry
      in .symbolic_link?
        target = entry.target
        return nil if target.nil?

        @filesystem.create_symlink(path, target) || entry
      in .untracked?, .problematic?
        nil
      end
    end

    private def incomplete?(intended : Core::Entry?, created : Core::Entry?) : Bool
      !Core::Entry.equal?(intended, created)
    end
  end
end
