require "../core/relocation"
require "../core/safety"
require "../write/writer"

module Pylon::Session
  struct Report
    def initialize(
      @conflicts : Array(Core::Conflict),
      @local_outcomes : Array(Write::Outcome),
      @remote_outcomes : Array(Write::Outcome),
      @troubles : Array(Core::Trouble),
      @halt : Core::Safety::Reason? = nil,
      @local_relocations : Array(Core::Relocation) = Array(Core::Relocation).new,
      @remote_relocations : Array(Core::Relocation) = Array(Core::Relocation).new,
    ) : Nil
    end

    getter conflicts : Array(Core::Conflict)
    getter local_outcomes : Array(Write::Outcome)
    getter remote_outcomes : Array(Write::Outcome)
    getter halt : Core::Safety::Reason?
    getter troubles : Array(Core::Trouble)
    getter local_relocations : Array(Core::Relocation)
    getter remote_relocations : Array(Core::Relocation)

    def halted? : Bool
      !halt.nil?
    end

    def skipped : Array(Write::Outcome)
      (local_outcomes + remote_outcomes).reject(&.applied?)
    end

    def quiet? : Bool
      conflicts.empty? &&
        local_outcomes.empty? &&
        remote_outcomes.empty? &&
        local_relocations.empty? &&
        remote_relocations.empty? &&
        !halted?
    end
  end
end
