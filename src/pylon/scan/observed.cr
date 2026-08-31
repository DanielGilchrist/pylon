require "./metadata"

module Pylon::Scan
  record ObservedFile, metadata : Metadata
  record ObservedDirectory
  record ObservedLink, target : String
  record ObservedUntracked

  alias Observed = ObservedFile | ObservedDirectory | ObservedLink | ObservedUntracked
end
