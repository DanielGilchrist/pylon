require "./paths"

module Pylon::Core
  module Reconciler
    extend self

    def reconcile(base : Entry?, local : Entry?, remote : Entry?, preferences : Preferences = Preferences.none) : Reconciliation
      state = State.new(preferences)
      state.walk("", base, local, remote)
      state.result
    end

    private struct State
      getter base_changes = [] of Change
      getter local_changes = [] of Change
      getter remote_changes = [] of Change
      getter conflicts = [] of Conflict

      def initialize(@preferences : Preferences)
      end

      def result : Reconciliation
        Reconciliation.new(base_changes, local_changes, remote_changes, conflicts)
      end

      def walk(path : String, base : Entry?, local : Entry?, remote : Entry?) : Nil
        return if unreadable?(local) || unreadable?(remote)

        if ignored?(local) && ignored?(remote)
          untrack(path, base)
          return
        end

        if Entry.equal?(local, remote)
          adopt(path, base, Entry.synchronizable(local))
          return
        end

        if blocked?(local) || blocked?(remote)
          record_conflict(path, base, local, remote)
          return
        end

        local_synchronizable = Entry.synchronizable(local)
        remote_synchronizable = Entry.synchronizable(remote)

        if local_synchronizable && remote_synchronizable &&
           local_synchronizable.directory? && remote_synchronizable.directory?
          descend(path, base, local_synchronizable, remote_synchronizable)
          return
        end

        merge(path, base, local_synchronizable, remote_synchronizable)
      end

      private def merge(path : String, base : Entry?, local : Entry?, remote : Entry?) : Nil
        local_changed = !Entry.equal?(base, local)
        remote_changed = !Entry.equal?(base, remote)

        return if !local_changed && !remote_changed

        if local_changed && !remote_changed
          propagate_to_remote(path, base, local, remote)
          return
        end

        if remote_changed && !local_changed
          propagate_to_local(path, base, local, remote)
          return
        end

        if local.nil? && !remote.nil?
          propagate_to_local(path, base, local, remote)
          return
        end

        if remote.nil? && !local.nil?
          propagate_to_remote(path, base, local, remote)
          return
        end

        case @preferences.winner(path)
        in Nil
          record_conflict(path, base, local, remote)
        in .local?
          propagate_to_remote(path, base, local, remote)
        in .remote?
          propagate_to_local(path, base, local, remote)
        end
      end

      private def descend(path : String, base : Entry?, local : Entry, remote : Entry) : Nil
        base_directory = base.try { |entry| entry.directory? ? entry : nil }

        if base_directory.nil?
          adopt(path, base, Entry.directory)
        end

        base_contents = (base_directory || Entry.directory).contents
        local_contents = local.contents
        remote_contents = remote.contents

        local_contents.each do |name, local_child|
          remote_child = remote_contents[name]?
          base_child = base_contents[name]?

          next if settled?(base_child, local_child, remote_child)

          walk(Paths.join(path, name), base_child, local_child, remote_child)
        end

        remote_contents.each do |name, remote_child|
          next if local_contents.has_key?(name)

          walk(Paths.join(path, name), base_contents[name]?, nil, remote_child)
        end

        base_contents.each do |name, base_child|
          next if local_contents.has_key?(name) || remote_contents.has_key?(name)

          walk(Paths.join(path, name), base_child, nil, nil)
        end
      end

      private def settled?(base : Entry?, local : Entry, remote : Entry?) : Bool
        return false if remote.nil?

        Entry.equal?(base, local) && local.equal?(remote)
      end

      private def propagate_to_remote(path : String, base : Entry?, local : Entry?, remote : Entry?) : Nil
        remote_changes << Change.new(path, remote, local)
        base_changes << Change.new(path, base, local)
      end

      private def propagate_to_local(path : String, base : Entry?, local : Entry?, remote : Entry?) : Nil
        local_changes << Change.new(path, local, remote)
        base_changes << Change.new(path, base, remote)
      end

      private def record_conflict(path : String, base : Entry?, local : Entry?, remote : Entry?) : Nil
        conflicts << Conflict.new(
          path,
          [Change.new(path, base, local)],
          [Change.new(path, base, remote)],
        )
      end

      private def adopt(path : String, base : Entry?, entry : Entry?) : Nil
        return if Entry.equal?(base, entry)

        base_changes << Change.new(path, base, entry)
      end

      private def untrack(path : String, base : Entry?) : Nil
        return if base.nil?

        base_changes << Change.new(path, base, nil)
      end

      private def unreadable?(entry : Entry?) : Bool
        !entry.nil? && entry.problematic?
      end

      private def ignored?(entry : Entry?) : Bool
        entry.nil? || entry.untracked?
      end

      private def blocked?(entry : Entry?) : Bool
        !entry.nil? && !entry.synchronizable?
      end
    end
  end
end
