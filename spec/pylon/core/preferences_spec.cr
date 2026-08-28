require "../../spec_helper"

private def build(local : Array(String) = [] of String, remote : Array(String) = [] of String) : Preferences
  case (preferences = Preferences.build(local, remote))
  in Preferences          then preferences
  in Preferences::Invalid then fail(preferences.message)
  end
end

describe Pylon::Core::Preferences do
  it "leaves everything a conflict when no rules are given" do
    Preferences.none.winner("sorbet/rbi/a.rbi").should be_nil
  end

  it "matches globs" do
    preferences = build(remote: ["**/*.rbi"])

    preferences.winner("sorbet/rbi/gems/a.rbi").should eq(Preferences::Side::Remote)
    preferences.winner("app/models/user.rb").should be_nil
  end

  it "covers the subtree when a rule names a directory" do
    preferences = build(remote: ["sorbet"])

    preferences.winner("sorbet/rbi/gems/a.rbi").should eq(Preferences::Side::Remote)
    preferences.winner("sorbet").should eq(Preferences::Side::Remote)
    preferences.winner("sorbet-config.rb").should be_nil
  end

  it "prefers local when explicit rules disagree" do
    preferences = build(local: ["app"], remote: ["app/**/*.rbi"])

    preferences.winner("app/models/user.rbi").should eq(Preferences::Side::Local)
  end

  it "applies the dot fallback only when nothing explicit matched" do
    preferences = build(local: ["."], remote: ["sorbet"])

    preferences.winner("sorbet/rbi/a.rbi").should eq(Preferences::Side::Remote)
    preferences.winner("app/models/user.rb").should eq(Preferences::Side::Local)
  end

  it "prefers a local fallback over a remote one" do
    build(local: ["."], remote: ["."]).winner("anything").should eq(Preferences::Side::Local)
  end

  it "refuses a malformed glob as a value" do
    Preferences.build(["[oops"], [] of String).should be_a(Preferences::Invalid)
  end
end
