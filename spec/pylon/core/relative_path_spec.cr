require "../../spec_helper"
require "../../../src/pylon/core/relative_path"

private alias Problem = Pylon::Problem
private alias RelativePath = Pylon::Core::RelativePath

describe RelativePath do
  it "parses the empty string as the root" do
    parsed = RelativePath.parse("")

    parsed.should be_a(RelativePath)
    parsed.value.should eq("") if parsed.is_a?(RelativePath)
  end

  it "parses an ordinary nested path" do
    parsed = RelativePath.parse("app/models/user.rb")

    parsed.should be_a(RelativePath)
    parsed.value.should eq("app/models/user.rb") if parsed.is_a?(RelativePath)
  end

  it "rejects a path with a NUL byte" do
    parsed = RelativePath.parse("app\0models")

    parsed.should be_a(Problem)
    parsed.reason.should eq("contains a NUL byte") if parsed.is_a?(Problem)
  end

  it "rejects a traversal in any segment" do
    {"..", "../x", "x/..", "a/../b"}.each do |raw|
      RelativePath.parse(raw).should be_a(Problem), "expected #{raw.inspect} to be rejected"
    end
  end

  it "rejects a current directory segment" do
    {".", "./x", "a/./b"}.each do |raw|
      RelativePath.parse(raw).should be_a(Problem), "expected #{raw.inspect} to be rejected"
    end
  end

  it "rejects empty segments from doubled or trailing slashes" do
    {"a//b", "a/", "/a"}.each do |raw|
      RelativePath.parse(raw).should be_a(Problem), "expected #{raw.inspect} to be rejected"
    end
  end
end
