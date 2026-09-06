module Pylon::Write
  enum Verdict
    Proceed
    ModificationDetected
    UnknownState
    Inconclusive

    def skip : Skip?
      case self
      in .proceed?                       then nil
      in .modification_detected?         then Skip::ModificationDetected
      in .unknown_state?, .inconclusive? then Skip::UnknownState
      end
    end
  end
end
