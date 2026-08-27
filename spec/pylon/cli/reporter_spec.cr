require "../../spec_helper"
require "../../../src/pylon/cli/reporter"

private def report_of(
  conflicts = [] of Conflict,
  local = [] of Pylon::Write::Outcome,
  remote = [] of Pylon::Write::Outcome,
  halt = nil,
) : Pylon::Session::Report
  Pylon::Session::Report.new(conflicts, local, remote, halt)
end

private def rendered(report, verbose = false, dry_run = false) : String
  Colorize.enabled = false
  io = IO::Memory.new
  Pylon::CLI::Reporter.new(io, verbose, dry_run).report(report)
  io.to_s
end

private def applied(path : String) : Pylon::Write::Outcome
  Pylon::Write::Outcome.new(path, Fixtures.f1)
end

private def removed(path : String) : Pylon::Write::Outcome
  Pylon::Write::Outcome.new(path, nil)
end

private def skipped(path : String, problem : String) : Pylon::Write::Outcome
  Pylon::Write::Outcome.new(path, nil, problem)
end

describe Pylon::CLI::Reporter do
  it "says nothing when a cycle was quiet" do
    rendered(report_of).should be_empty
  end

  it "names what moved and which way it went" do
    output = rendered(report_of(local: [applied("came/down.rb")], remote: [applied("went/up.rb")]))

    output.should contain("↑ went/up.rb")
    output.should contain("↓ came/down.rb")
  end

  it "stops naming files once there are too many" do
    outcomes = (1..20).map { |index| applied("file_#{index}.rb") }

    output = rendered(report_of(remote: outcomes))

    output.should contain("file_1.rb")
    output.should contain("and 14 more")
    output.should_not contain("file_20.rb")
  end

  it "names every file when asked to be verbose" do
    outcomes = (1..20).map { |index| applied("file_#{index}.rb") }

    output = rendered(report_of(remote: outcomes), verbose: true)

    output.should contain("file_20.rb")
    output.should_not contain("more")
  end

  it "explains a conflict rather than just counting it" do
    output = rendered(report_of(conflicts: [Conflict.new("db/structure.sql", [] of Change, [] of Change)]))

    output.should contain("conflict")
    output.should contain("db/structure.sql")
    output.should contain("left alone on both sides")
  end

  it "points at the flag that explains a skip" do
    report = report_of(remote: [skipped("notes.txt", "modification detected")])

    quiet = rendered(report)
    quiet.should contain("1 skipped")
    quiet.should contain("PYLON_VERBOSE")
    quiet.should_not contain("modification detected")

    rendered(report, verbose: true).should contain("modification detected")
  end

  it "leads with the halt and says nothing changed" do
    output = rendered(report_of(halt: Safety::Reason::EndpointEmptiedRoot))

    output.should contain("halted")
    output.should contain("nothing was changed on either side")
  end

  it "shows a dry run as intentions, including deletions" do
    output = rendered(report_of(remote: [applied("new.rb"), removed("gone.rb")]), dry_run: true)

    output.should contain("dry run")
    output.should contain("nothing will be changed")
    output.should contain("write  new.rb")
    output.should contain("delete gone.rb")
  end

  it "says there is nothing to do on an empty dry run" do
    rendered(report_of, dry_run: true).should contain("nothing to do")
  end
end
