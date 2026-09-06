require "../../spec_helper"

private alias Preferences = Pylon::Core::Preferences
private alias Problem = Pylon::Problem

private def build(
  local : Array(String) = Array(String).new,
  remote : Array(String) = Array(String).new,
) : Preferences
  case (preferences = Preferences.build(local, remote))
  in Preferences then preferences
  in Problem     then fail(preferences.reason)
  end
end

describe Preferences do
  it "leaves everything a conflict when no rules are given" do
    build.winner("sorbet/rbi/a.rbi").should be_nil
  end

  it "matches globs" do
    preferences = build(remote: ["**/*.rbi"])

    preferences.winner("sorbet/rbi/gems/a.rbi").should eq(Pylon::Replica::Remote)
    preferences.winner("app/models/user.rb").should be_nil
  end

  it "covers the subtree when a rule names a directory" do
    preferences = build(remote: ["sorbet"])

    preferences.winner("sorbet/rbi/gems/a.rbi").should eq(Pylon::Replica::Remote)
    preferences.winner("sorbet").should eq(Pylon::Replica::Remote)
    preferences.winner("sorbet-config.rb").should be_nil
  end

  it "prefers local when explicit rules disagree" do
    preferences = build(local: ["app"], remote: ["app/**/*.rbi"])

    preferences.winner("app/models/user.rbi").should eq(Pylon::Replica::Local)
  end

  it "applies the dot fallback only when nothing explicit matched" do
    preferences = build(local: ["."], remote: ["sorbet"])

    preferences.winner("sorbet/rbi/a.rbi").should eq(Pylon::Replica::Remote)
    preferences.winner("app/models/user.rb").should eq(Pylon::Replica::Local)
  end

  it "prefers a local fallback over a remote one" do
    build(local: ["."], remote: ["."]).winner("anything").should eq(Pylon::Replica::Local)
  end

  it "refuses a malformed glob as a value" do
    Preferences.build(["[oops"], Array(String).new).should be_a(Problem)
  end

  it "refuses a malformed glob when the bad segment is not the first" do
    Preferences.build(["src/[abc"], Array(String).new).should be_a(Problem)
  end

  it "refuses a malformed glob on the remote side too" do
    Preferences.build(Array(String).new, ["[oops"]).should be_a(Problem)
  end

  it "never raises while matching a rule it accepted" do
    preferences = build(local: ["src/deep/nested/thing"])

    preferences.winner("src/deep/nested/thing/file.rb").should eq(Pylon::Replica::Local)
  end
end
