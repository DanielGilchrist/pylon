require "../core/entry"
require "../scan/cache_entry"
require "./verdict"

module Pylon::Write
  module Guard
    extend self

    def check(expected : Core::Entry?, cached : Scan::CacheEntry?, observed : Scan::Metadata?) : Verdict
      return observed.nil? ? Verdict::Proceed : Verdict::ModificationDetected if expected.nil?
      return Verdict::ModificationDetected if observed.nil?

      case expected.kind
      in .directory?
        observed.kind.directory? ? Verdict::Proceed : Verdict::ModificationDetected
      in .symbolic_link?
        observed.kind.symbolic_link? ? Verdict::Proceed : Verdict::ModificationDetected
      in .file?
        file(expected, cached, observed)
      in .untracked?, .problematic?
        Verdict::UnknownState
      end
    end

    private def file(expected : Core::Entry, cached : Scan::CacheEntry?, observed : Scan::Metadata) : Verdict
      return Verdict::UnknownState if cached.nil?
      return Verdict::ModificationDetected unless cached.metadata.reusable?(observed)
      return Verdict::ModificationDetected unless cached.digest == expected.digest

      Verdict::Proceed
    end
  end
end
