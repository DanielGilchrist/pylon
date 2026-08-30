require "../write/writer"
require "./fault"

module Pylon::Session
  struct PendingWrite
    def initialize(@receive : Proc(Array(Write::Outcome) | Fault))
    end

    def await : Array(Write::Outcome) | Fault
      @receive.call
    end
  end
end
