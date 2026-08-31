require "../../spec_helper"
require "../../../src/pylon/core/safety"

private def populated : Entry
  Pylon::Core::Directory.new({"a" => Fixtures.f1, "b" => Fixtures.f2})
end

private NO_CHANGES = [] of Change

describe Pylon::Core::Safety do
  it "allows an ordinary cycle" do
    Safety.check(populated, populated, populated, NO_CHANGES).should be_nil
  end

  it "halts when one side lost everything" do
    Safety.check(populated, Pylon::Core::Directory.new, populated, NO_CHANGES)
      .should eq(Safety::Reason::EndpointEmptiedRoot)

    Safety.check(populated, populated, nil, NO_CHANGES)
      .should eq(Safety::Reason::EndpointEmptiedRoot)
  end

  it "allows both sides emptying, which is a deliberate act" do
    Safety.check(populated, Pylon::Core::Directory.new, Pylon::Core::Directory.new, NO_CHANGES).should be_nil
  end

  it "ignores a root that never had much in it" do
    small = Pylon::Core::Directory.new({"a" => Fixtures.f1})

    Safety.check(small, Pylon::Core::Directory.new, small, NO_CHANGES).should be_nil
  end

  it "does not count ignored children towards a populated root" do
    ignored = Pylon::Core::Directory.new({"a" => Fixtures.untracked, "b" => Fixtures.untracked})

    Safety.check(ignored, Pylon::Core::Directory.new, ignored, NO_CHANGES).should be_nil
  end

  it "halts on a change that would delete the root" do
    Safety.check(populated, populated, populated, [Change.new("", populated, nil)])
      .should eq(Safety::Reason::RootDeletion)
  end

  it "halts on a change that would replace the root with a file" do
    Safety.check(populated, populated, populated, [Change.new("", populated, Fixtures.f1)])
      .should eq(Safety::Reason::RootTypeChange)
  end

  it "calls a root type change by its name even though one side no longer holds a directory" do
    Safety.check(populated, Fixtures.f1, populated, [Change.new("", populated, Fixtures.f1)])
      .should eq(Safety::Reason::RootTypeChange)
  end

  it "allows creating the root where there was nothing" do
    Safety.check(nil, nil, populated, [Change.new("", nil, populated)]).should be_nil
  end

  it "allows a root change that keeps its type" do
    bigger = Pylon::Core::Directory.new({"a" => Fixtures.f1, "b" => Fixtures.f2, "c" => Fixtures.f1})

    Safety.check(populated, populated, populated, [Change.new("", populated, bigger)]).should be_nil
  end

  it "allows deleting something that is not the root" do
    Safety.check(populated, populated, populated, [Change.new("a", Fixtures.f1, nil)]).should be_nil
  end

  it "explains every reason it can give" do
    Safety::Reason.each do |reason|
      reason.explain.should_not be_empty
    end
  end
end
