require "../../spec_helper"
require "../../../src/pylon/cli/target"

describe Pylon::CLI::Target do
  it "splits a user, host and path" do
    target = Pylon::CLI::Target.parse("user@host:/srv/app")

    target.should be_a(Pylon::CLI::Target)
    next unless target.is_a?(Pylon::CLI::Target)

    target.host.should eq("user@host")
    target.path.should eq("/srv/app")
  end

  it "keeps a relative remote path" do
    Pylon::CLI::Target.parse("host:app").as(Pylon::CLI::Target).path.should eq("app")
  end

  it "splits on the first colon so the path may contain one" do
    Pylon::CLI::Target.parse("host:/srv/a:b").as(Pylon::CLI::Target).path.should eq("/srv/a:b")
  end

  it "explains a target with no colon" do
    Pylon::CLI::Target.parse("host").as(Pylon::CLI::Target::Invalid).message.should contain("user@host:/path")
  end

  it "explains a target missing a host or a path" do
    Pylon::CLI::Target.parse(":/srv/app").as(Pylon::CLI::Target::Invalid).message.should contain("missing a host")
    Pylon::CLI::Target.parse("host:").as(Pylon::CLI::Target::Invalid).message.should contain("missing a path")
  end
end
