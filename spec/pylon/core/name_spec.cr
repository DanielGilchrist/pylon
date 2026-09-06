require "../../spec_helper"
require "../../../src/pylon/core/name"

private alias Name = Pylon::Core::Name
private alias Problem = Pylon::Problem

describe Name do
  it "accepts an ordinary path component" do
    parsed = Name.parse("user.rb")

    parsed.should be_a(Name)
    parsed.value.should eq("user.rb") if parsed.is_a?(Name)
  end

  it "accepts a component that merely contains dots" do
    {".hidden", "a.b.c", "...", "..x", "x.."}.each do |raw|
      Name.parse(raw).should be_a(Name), "expected #{raw.inspect} to be accepted"
    end
  end

  it "rejects an empty component" do
    parsed = Name.parse("")

    parsed.should be_a(Problem)
    parsed.reason.should eq("is empty") if parsed.is_a?(Problem)
  end

  it "rejects a component with a NUL byte" do
    parsed = Name.parse("a\0b")

    parsed.should be_a(Problem)
    parsed.reason.should eq("is a path component with a NUL byte") if parsed.is_a?(Problem)
  end

  it "rejects a component with a slash" do
    parsed = Name.parse("a/b")

    parsed.should be_a(Problem)
    parsed.reason.should eq("is a path component with a '/'") if parsed.is_a?(Problem)
  end

  it "rejects the current directory component" do
    parsed = Name.parse(".")

    parsed.should be_a(Problem)
    parsed.reason.should eq("is a '.' path component") if parsed.is_a?(Problem)
  end

  it "rejects the parent directory component" do
    parsed = Name.parse("..")

    parsed.should be_a(Problem)
    parsed.reason.should eq("is a '..' path component") if parsed.is_a?(Problem)
  end
end
