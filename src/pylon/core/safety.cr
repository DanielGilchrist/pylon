require "./change"
require "./entry"

module Pylon::Core
  module Safety
    extend self

    enum Reason
      EndpointEmptiedRoot
      RootDeletion
      RootTypeChange

      def explain : String
        case self
        in .endpoint_emptied_root? then "one side lost everything it had; refusing to mirror that"
        in .root_deletion?         then "a change would delete the sync root"
        in .root_type_change?      then "a change would replace the sync root with something else"
        end
      end
    end

    def check(
      base : Entry?,
      local : Entry?,
      remote : Entry?,
      changes : Array(Change),
    ) : Reason?
      return Reason::EndpointEmptiedRoot if emptied_root?(base, local, remote)

      changes.each do |change|
        next unless change.path.empty?

        return Reason::RootDeletion if change.new.nil?

        old = change.old
        new = change.new

        if old && new && old.class != new.class
          return Reason::RootTypeChange
        end
      end

      nil
    end

    private def emptied_root?(base : Entry?, local : Entry?, remote : Entry?) : Bool
      return false unless base.is_a?(Directory)
      return false if synchronizable_children(base) < 2

      empty?(local) != empty?(remote)
    end

    private def empty?(entry : Entry?) : Bool
      return true if entry.nil?
      return false unless entry.is_a?(Directory)

      synchronizable_children(entry).zero?
    end

    private def synchronizable_children(entry : Directory) : Int32
      entry.contents.each_value.count(&.synchronizable?)
    end
  end
end
