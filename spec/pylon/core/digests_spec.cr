require "../../spec_helper"
require "../../../src/pylon/core/digests"

describe Pylon::Core::Digests do
  it "asks for each digest once no matter how many changes share it" do
    changes = [
      Change.new("a.rb", nil, Fixtures.f1),
      Change.new("copy_of_a.rb", nil, Fixtures.f1),
      Change.new("b.rb", nil, Fixtures.f2),
    ]

    Digests.required(changes).should eq([Fixtures::D1, Fixtures::D2])
  end

  it "walks into directories and ignores everything without content" do
    subtree = Fixtures.dir({
      "nested" => Fixtures.dir({"file" => Fixtures.f2}),
      "link"   => Fixtures.symlink_relative,
      "odd"    => Fixtures.untracked,
    })

    changes = [
      Change.new("app", nil, subtree),
      Change.new("gone.rb", Fixtures.f1, nil),
    ]

    Digests.required(changes).should eq([Fixtures::D2])
  end
end
