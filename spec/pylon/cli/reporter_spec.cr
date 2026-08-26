require "../../spec_helper"
require "../../../src/pylon/cli/reporter"

include Pylon::CLI

private def report_of(
  conflicts = [] of Conflict,
  local = [] of Pylon::Write::Outcome,
  remote = [] of Pylon::Write::Outcome,
) : Pylon::Session::Report
  Pylon::Session::Report.new(conflicts, local, remote)
end

private def rendered(report, verbose = false) : String
  io = IO::Memory.new
  Reporter.new(io, verbose).report(report)
  io.to_s
end

private def applied(path : String) : Pylon::Write::Outcome
  Pylon::Write::Outcome.new(path, Fixtures.f1)
end

private def skipped(path : String, problem : String) : Pylon::Write::Outcome
  Pylon::Write::Outcome.new(path, nil, problem)
end

describe Pylon::CLI::Reporter do
  it "says nothing when a cycle was quiet" do
    rendered(report_of).should be_empty
  end

  it "counts what moved in each direction" do
    rendered(report_of(local: [applied("a")], remote: [applied("b"), applied("c")]))
      .should eq("2 out, 1 in\n")
  end

  it "names every conflict without being asked" do
    output = rendered(report_of(conflicts: [Conflict.new("db/structure.sql", [] of Change, [] of Change)]))

    output.should contain("1 conflicted")
    output.should contain("conflict  db/structure.sql")
  end

  it "counts skipped paths but keeps the reason for verbose mode" do
    report = report_of(remote: [skipped("notes.txt", "modification detected")])

    quiet = rendered(report)
    quiet.should eq("1 skipped\n")
    quiet.should_not contain("modification detected")

    rendered(report, verbose: true).should contain("skipped   notes.txt  (modification detected)")
  end

  it "reports a quiet cycle when asked to be verbose" do
    rendered(report_of, verbose: true).should eq("nothing to do\n")
  end
end
