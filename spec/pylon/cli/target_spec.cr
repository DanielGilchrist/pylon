require "../../spec_helper"

private alias Problem = Pylon::Problem
private alias Target = Pylon::CLI::Target

describe Target do
  it "splits a user, host and path" do
    target = Target.parse("user@host:/srv/app")

    target.should be_a(Target)
    next unless target.is_a?(Target)

    target.host.should eq("user@host")
    target.path.should eq("/srv/app")
  end

  it "keeps a relative remote path" do
    Target.parse("host:app").as(Target).path.should eq("app")
  end

  it "splits on the first colon so the path may contain one" do
    Target.parse("host:/srv/a:b").as(Target).path.should eq("/srv/a:b")
  end

  it "explains a target with no colon" do
    Target.parse("host").as(Problem).reason.should contain(
      "user@host:/path",
    )
  end

  it "explains a target missing a host or a path" do
    Target.parse(":/srv/app").as(Problem).reason.should contain(
      "missing a host",
    )
    Target.parse("host:").as(Problem).reason.should contain(
      "missing a path",
    )
  end

  it "refuses a host ssh would read as an option" do
    result = Target.parse("-oProxyCommand=touch /tmp/x:/srv/app")

    result.should be_a(Problem)
    result.as(Problem).reason.should contain("ssh would read as an option")
  end
end
