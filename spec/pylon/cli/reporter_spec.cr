require "../../spec_helper"
require "../../../src/pylon/cli/reporter"

private def report_of(
  conflicts = Array(String).new,
  local = Array(Pylon::Write::Outcome).new,
  remote = Array(Pylon::Write::Outcome).new,
  halt = nil,
  troubles = Array(Trouble).new,
) : Pylon::Session::Report
  Pylon::Session::Report.new(conflicts, local, remote, troubles, halt)
end

private def rendered(
  report : Pylon::Session::Report,
  verbose = false,
  dry_run = false,
  elapsed : Time::Span? = nil,
) : String
  Colorize.enabled = false
  io = IO::Memory.new
  Pylon::CLI::Reporter.new(io, verbose, dry_run, brand: Pylon::Brand::DEFAULT).report(
    report,
    elapsed,
  )
  io.to_s
end

private def applied(path : String) : Pylon::Write::Outcome
  Pylon::Write::Outcome.new(path, Fixtures.f1)
end

private def removed(path : String) : Pylon::Write::Outcome
  Pylon::Write::Outcome.new(path, nil)
end

private def skipped(
  path : String,
  reason : Pylon::Write::Skipped = Pylon::Write::Skip::ModificationDetected,
) : Pylon::Write::Outcome
  Pylon::Write::Outcome.new(path, nil, reason)
end

private def moved(from : String, to : String) : Pylon::Core::Relocation
  Pylon::Core::Relocation.new(from, to, Fixtures.directory!(Fixtures.d1))
end

private def report_with_moves(
  remote : Array(Pylon::Write::Outcome),
  moves : Array(Pylon::Core::Relocation),
) : Pylon::Session::Report
  Pylon::Session::Report.new(
    Array(String).new,
    Array(Pylon::Write::Outcome).new,
    remote,
    Array(Trouble).new,
    remote_relocations: moves,
  )
end

private def reporter_waiting_on_the_remote(inbound : Pylon::Session::Inbound) : Pylon::CLI::Reporter
  Colorize.enabled = false
  reporter = Pylon::CLI::Reporter.new(IO::Memory.new, false, false, brand: Pylon::Brand::DEFAULT)
  progress = Pylon::Progress.new
  100.times { progress.add_file }
  progress.finish
  reporter.observe(progress, Pylon::Progress.new)
  reporter.observe(inbound)
  reporter
end

describe "the startup status line" do
  it "says the remote has not spoken yet" do
    inbound = Pylon::Session::Inbound.new

    reporter_waiting_on_the_remote(inbound).scan_status.should eq(
      "waiting for the remote · 100 files here",
    )
  end

  it "relays the remote scan's counters" do
    inbound = Pylon::Session::Inbound.new
    inbound.scanning(1234_i64, 0_i64)
    reporter_waiting_on_the_remote(inbound).scan_status.should eq("remote scanning · 1234 files")

    inbound.scanning(1234_i64, 3_i64 * 1024 * 1024)
    reporter_waiting_on_the_remote(inbound).scan_status.should eq(
      "remote scanning · 1234 files · 3.0 MiB hashed",
    )
  end

  it "shows how much of the announced tree has arrived" do
    inbound = Pylon::Session::Inbound.new
    inbound.arrived(700)
    inbound.announced(2_u32 * 1024 * 1024)
    inbound.arrived(512 * 1024)

    reporter_waiting_on_the_remote(inbound).scan_status.should start_with(
      "receiving the remote tree · 512 KiB of 2.0 MiB",
    )
  end

  it "never reports more of the tree than was announced" do
    inbound = Pylon::Session::Inbound.new
    inbound.announced(1024_u32)
    inbound.arrived(5000)

    reporter_waiting_on_the_remote(inbound).scan_status.should start_with(
      "receiving the remote tree · 1 KiB of 1 KiB",
    )
  end
end

describe Pylon::CLI::Reporter do
  it "says nothing when a cycle was quiet" do
    rendered(report_of).should be_empty
  end

  it "says how long a sync took when it moved anything" do
    output = rendered(report_of(remote: [applied("went/up.rb")]), elapsed: 240.milliseconds)

    output.should contain("synced in 240 ms")
  end

  it "keeps quiet cycles silent even when timed" do
    rendered(report_of, elapsed: 240.milliseconds).should be_empty
  end

  it "leaves the timing off a halted cycle" do
    output = rendered(report_of(halt: Safety::Reason::RootDeletion), elapsed: 240.milliseconds)

    output.should_not contain("synced in")
  end

  it "names what moved and which way it went" do
    output = rendered(report_of(local: [applied("came/down.rb")], remote: [applied("went/up.rb")]))

    output.should contain("↑ went/up.rb")
    output.should contain("↓ came/down.rb")
  end

  it "names a handful of files and counts the rest" do
    outcomes = (1..10).map { |index| applied("app/file_#{index}.rb") }

    output = rendered(report_of(remote: outcomes))

    output.should contain("app/file_1.rb")
    output.should contain("and 4 more")
    output.should_not contain("app/file_9.rb")
  end

  it "summarises a large batch by directory rather than listing it" do
    outcomes = (1..250).map { |index| applied("app/models/f#{index}.rb") }
    outcomes << applied("db/structure.sql")

    output = rendered(report_of(remote: outcomes))

    output.should contain("251 files")
    output.should contain("app/models")
    output.should contain("db")
    output.should_not contain("f137.rb")
  end

  it "names every file when asked to be verbose" do
    outcomes = (1..20).map { |index| applied("file_#{index}.rb") }

    output = rendered(report_of(remote: outcomes), verbose: true)

    output.should contain("file_20.rb")
    output.should_not contain("more")
  end

  it "explains a conflict rather than just counting it" do
    output = rendered(
      report_of(conflicts: ["db/structure.sql"]),
    )

    output.should contain("conflict")
    output.should contain("db/structure.sql")
    output.should contain("--prefer-local")
  end

  it "groups a flood of conflicts by directory" do
    conflicts = Array.new(30) do |index|
      "config/locales/translation.#{index}.yml"
    end

    output = rendered(report_of(conflicts: conflicts))

    output.should contain("30 conflicts")
    output.should contain("config/locales")
    output.should contain("--prefer")
    output.should_not contain("translation.7.yml")
  end

  it "mentions a conflict once, not on every cycle, and says when it clears" do
    Colorize.enabled = false
    io = IO::Memory.new
    reporter = Pylon::CLI::Reporter.new(io, false, false, brand: Pylon::Brand::DEFAULT)
    conflict = report_of(conflicts: ["db/structure.sql"])

    reporter.report(conflict, nil)
    first = io.to_s
    io.clear

    reporter.report(conflict, nil)
    io.to_s.should be_empty

    reporter.report(report_of, nil)
    first.should contain("conflict")
    io.to_s.should contain("conflict resolved")
  end

  it "says which side an unsyncable path is on and why it matters" do
    output = rendered(report_of(troubles: [Trouble.new("locked.rb", :remote, "permission denied")]))

    output.should contain("cannot sync on the remote")
    output.should contain("locked.rb")
    output.should contain("permission denied")
    output.should contain("will not sync")

    rendered(report_of(troubles: [Trouble.new("locked.rb", :local, "permission denied")]))
      .should_not contain("on the remote")
  end

  it "mentions an unsyncable path once, not on every cycle" do
    Colorize.enabled = false
    io = IO::Memory.new
    reporter = Pylon::CLI::Reporter.new(io, false, false, brand: Pylon::Brand::DEFAULT)
    troubled = report_of(troubles: [Trouble.new("locked.rb", :local, "permission denied")])

    reporter.report(troubled, nil)
    io.to_s.should contain("cannot sync")
    io.clear

    reporter.report(troubled, nil)
    io.to_s.should be_empty
  end

  it "counts the directories it does not name in a summary" do
    outcomes = (1..40).flat_map do |index|
      [
        applied("app/f#{index}.rb"),
        applied("lib/f#{index}.rb"),
        applied("db/f#{index}.rb"),
        applied("bin/f#{index}.rb"),
      ]
    end

    output = rendered(report_of(remote: outcomes.to_a))

    output.should contain("160 files")
    output.should contain("and 1 more")
  end

  it "does not claim more directories when it named them all" do
    outcomes = (1..20).flat_map do |index|
      [applied("app/f#{index}.rb"), applied("lib/f#{index}.rb")]
    end

    output = rendered(report_of(remote: outcomes.to_a))

    output.should_not contain("more")
  end

  it "names a move once rather than as a removal and a write" do
    report = report_with_moves(
      [removed("lib"), Pylon::Write::Outcome.new("moved", Fixtures.d1)],
      [moved("lib", "moved")],
    )

    output = rendered(report)

    output.should contain("↑ lib → moved")
    output.should_not contain("removed")
  end

  it "counts moves in a summarised batch" do
    outcomes = (1..20).map { |index| applied("app/file_#{index}.rb") }
    outcomes << removed("lib") << Pylon::Write::Outcome.new("moved", Fixtures.d1)

    output = rendered(report_with_moves(outcomes, [moved("lib", "moved")]))

    output.should contain("20 files")
    output.should contain("1 moved")
    output.should_not contain("removed")
  end

  it "previews a move as a move" do
    output = rendered(
      report_with_moves(Array(Pylon::Write::Outcome).new, [moved("lib", "moved")]),
      dry_run: true,
    )

    output.should contain("move")
    output.should contain("lib → moved")
    output.should_not contain("nothing to do")
  end

  it "says when an uploaded path was actually a deletion" do
    output = rendered(report_of(remote: [removed("gone.rb")]))

    output.should contain("gone.rb")
    output.should contain("removed")
  end

  it "keeps skips out of normal output and explains them in verbose mode" do
    report = report_of(remote: [skipped("notes.txt")])

    quiet = rendered(report)
    quiet.should_not contain("skipped")
    quiet.should_not contain("notes.txt")

    verbose = rendered(report, verbose: true)
    verbose.should contain("1 skipped")
    verbose.should contain("modification detected")
  end

  it "leads with the halt and says nothing changed" do
    output = rendered(report_of(halt: Safety::Reason::RootDeletion))

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

  it "sends a failure to the error stream on its own line" do
    Colorize.enabled = false
    output = IO::Memory.new
    errors = IO::Memory.new

    reporter = Pylon::CLI::Reporter.new(
      output,
      false,
      false,
      errors: errors,
      brand: Pylon::Brand::DEFAULT,
    )
    reporter.failed("the remote server stopped")

    errors.to_s.should eq("pylon: the remote server stopped\n")
    output.to_s.should be_empty
  end

  it "signs its output with the given name instead of pylon" do
    Colorize.enabled = false
    output = IO::Memory.new
    errors = IO::Memory.new
    reporter = Pylon::CLI::Reporter.new(
      output,
      false,
      false,
      errors: errors,
      brand: Pylon::Brand.new("Test Sync"),
    )

    reporter.starting("./app", "user@host:/srv/app")
    reporter.warn("the state file was ignored")
    reporter.failed("the remote server stopped")

    output.to_s.should contain("Test Sync app → user@host:/srv/app")
    errors.to_s.should eq(
      "Test Sync: the state file was ignored\nTest Sync: the remote server stopped\n",
    )
  end

  it "passes a remote line through to the error stream" do
    Colorize.enabled = false
    output = IO::Memory.new
    errors = IO::Memory.new

    reporter = Pylon::CLI::Reporter.new(
      output,
      false,
      false,
      errors: errors,
      brand: Pylon::Brand::DEFAULT,
    )
    reporter.relay("sh: pylon: not found")

    errors.to_s.should contain("remote sh: pylon: not found")
    output.to_s.should be_empty
  end
end
