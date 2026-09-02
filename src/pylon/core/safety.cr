require "./change"
require "./entry"

module Pylon::Core
  module Safety
    extend self

    enum Reason
      RootDeletion
      RootTypeChange

      def explain : String
        case self
        in .root_deletion?    then "a change would delete the sync root"
        in .root_type_change? then "a change would replace the sync root with something else"
        end
      end
    end

    def check(changes : Changes) : Reason?
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
  end
end
