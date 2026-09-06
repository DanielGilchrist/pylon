module Pylon::Scan
  alias Observed = ObservedFile | ObservedDirectory | ObservedLink | ObservedUntracked

  record ObservedFile, metadata : Metadata
  record ObservedDirectory
  record ObservedLink, target : String
  record ObservedUntracked
end
