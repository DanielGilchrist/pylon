require "../core/change"
require "../core/entry"
require "../scan/cache_entry"
require "./guard"
require "./outcome"

module Pylon::Write
  struct Writer(F, S)
    def initialize(@filesystem : F, @staging : S, @cache : Scan::Cache)
    end

    def write(changes : Array(Core::Change)) : Array(Outcome)
      changes.map { |change| write_one(change) }
    end

    private def write_one(change : Core::Change) : Outcome
      verdict = Guard.check(
        change.old,
        @cache[change.path]?,
        @filesystem.metadata(change.path),
      )

      case verdict
      in Verdict::ModificationDetected
        return Outcome.new(change.path, change.old, "modification detected")
      in Verdict::UnknownState
        return Outcome.new(change.path, change.old, "unknown state")
      in Verdict::Proceed
      end

      if (swapped = swap_permissions(change))
        return swapped
      end

      @filesystem.remove(change.path) if clear_first?(change.old, change.new)

      created = create(change.path, change.new)

      return Outcome.new(change.path, created, "staged content missing") if incomplete?(change.new, created)

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

      return nil unless @filesystem.set_executable(change.path, new.executable?)

      Outcome.new(change.path, new)
    end

    private def create(path : String, entry : Core::Entry?) : Core::Entry?
      return nil if entry.nil?

      case entry.kind
      in Core::Entry::Kind::Directory
        return nil unless @filesystem.create_directory(path)

        contents = {} of String => Core::Entry

        entry.contents.each do |name, child|
          if (created = create(join(path, name), child))
            contents[name] = created
          end
        end

        Core::Entry.directory(contents)
      in Core::Entry::Kind::File
        digest = entry.digest
        return nil if digest.nil?

        content = @staging.content(digest)
        return nil if content.nil?

        return nil unless @filesystem.write_file(path, content, entry.executable?)

        entry
      in Core::Entry::Kind::SymbolicLink
        target = entry.target
        return nil if target.nil?
        return nil unless @filesystem.create_symlink(path, target)

        entry
      in Core::Entry::Kind::Untracked, Core::Entry::Kind::Problematic
        nil
      end
    end

    private def incomplete?(intended : Core::Entry?, created : Core::Entry?) : Bool
      !Core::Entry.equal?(intended, created, true)
    end

    private def join(path : String, name : String) : String
      path.empty? ? name : "#{path}/#{name}"
    end
  end
end
