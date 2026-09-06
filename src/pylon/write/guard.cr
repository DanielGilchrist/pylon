module Pylon::Write
  module Guard
    extend self

    def check(
      expected : Core::Entry?,
      cached : Scan::CacheEntry?,
      observed : Scan::Observed | Problem | Nil,
      now_ns : Int64,
    ) : Verdict
      return Verdict::UnknownState if observed.is_a?(Problem)
      return observed.nil? ? Verdict::Proceed : Verdict::ModificationDetected if expected.nil?
      return Verdict::ModificationDetected if observed.nil?

      case expected
      in Core::Directory
        observed.is_a?(Scan::ObservedDirectory) ? Verdict::Proceed : Verdict::ModificationDetected
      in Core::SymbolicLink
        link(expected, observed)
      in Core::File
        if observed.is_a?(Scan::ObservedFile)
          file(expected, cached, observed.metadata, now_ns)
        else
          Verdict::ModificationDetected
        end
      in Core::Untracked, Core::Problematic
        Verdict::UnknownState
      end
    end

    private def link(expected : Core::SymbolicLink, observed : Scan::Observed) : Verdict
      return Verdict::ModificationDetected unless observed.is_a?(Scan::ObservedLink)

      observed.target == expected.target ? Verdict::Proceed : Verdict::ModificationDetected
    end

    private def file(
      expected : Core::File,
      cached : Scan::CacheEntry?,
      observed : Scan::Metadata,
      now_ns : Int64,
    ) : Verdict
      return Verdict::UnknownState if cached.nil?
      return Verdict::Inconclusive if cached.freshly_written?
      if observed.freshly_modified?(now_ns, Scan::Metadata::GRANULARITY_NS)
        return Verdict::Inconclusive
      end
      return Verdict::ModificationDetected unless cached.metadata.reusable?(observed)
      return Verdict::ModificationDetected unless cached.digest == expected.digest

      Verdict::Proceed
    end
  end
end
