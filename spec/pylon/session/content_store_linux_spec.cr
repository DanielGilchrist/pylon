{% skip_file unless flag?(:linux) %}

require "file_utils"
require "../../spec_helper"
require "../../../src/pylon/session/content_store"

include Pylon::Session

describe Pylon::Session::ContentStore do
  it "is unavailable on Linux until file cloning is implemented there" do
    directory = File.join(Dir.tempdir, "pylon-store-#{Random::Secure.hex(8)}")

    begin
      opened = ContentStore.open(directory)

      opened.should be_a(ContentStore::Unavailable)
      opened.reason.should contain("not implemented on Linux yet") if opened.is_a?(ContentStore::Unavailable)
      Dir.children(directory).should be_empty
    ensure
      FileUtils.rm_rf(directory)
    end
  end
end
