require "../../spec_helper"
require "../../../src/pylon/core/safety"

private alias Change = Pylon::Core::Change
private alias Changes = Pylon::Core::Changes
private alias Directory = Pylon::Core::Directory
private alias Safety = Pylon::Core::Safety

private def populated : Pylon::Core::Entry
  Directory.new({"a" => Fixtures.f1, "b" => Fixtures.f2})
end

private NO_CHANGES = Changes.new

describe Safety do
  it "allows an ordinary cycle" do
    Safety.check(NO_CHANGES).should be_nil
  end

  it "halts on a change that would delete the root" do
    Safety.check(Changes[Change.new("", populated, nil)])
      .should eq(Pylon::Core::Safety::Reason::RootDeletion)
  end

  it "halts on a change that would replace the root with a file" do
    Safety.check(Changes[Change.new("", populated, Fixtures.f1)])
      .should eq(Pylon::Core::Safety::Reason::RootTypeChange)
  end

  it "allows creating the root where there was nothing" do
    Safety.check(Changes[Change.new("", nil, populated)]).should be_nil
  end

  it "allows a root change that keeps its type" do
    bigger = Directory.new(
      {"a" => Fixtures.f1, "b" => Fixtures.f2, "c" => Fixtures.f1},
    )

    Safety.check(Changes[Change.new("", populated, bigger)]).should be_nil
  end

  it "allows deleting something that is not the root" do
    Safety.check(Changes[Change.new("a", Fixtures.f1, nil)]).should be_nil
  end

  it "explains every reason it can give" do
    Pylon::Core::Safety::Reason.each do |reason|
      reason.explain.should_not be_empty
    end
  end
end
