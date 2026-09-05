require "colorize"
require "../brand"
require "../progress"
require "../session/inbound"
require "../session/session"
require "./spinner"

struct Pylon::CLI
  class Reporter
    NAMED_PATHS    =  6
    SUMMARISE_OVER = 12
    PREVIEW_PATHS  = 40

    @progress : Session::TransferProgress? = nil
    @scan : Progress? = nil
    @sent : Progress? = nil
    @inbound : Session::Inbound? = nil

    def initialize(
      @io : IO,
      @verbose : Bool,
      @dry_run : Bool,
      @errors : IO = STDERR,
      *,
      @brand : Brand,
    ) : Nil
      @announced = Set(String).new
      @announced_troubles = Set(String).new
      @spinner = Spinner.new(@io)
      @sent_before = 0_i64
      @started = Time.instant
    end

    def observe(scan : Progress, sent : Progress) : Nil
      @scan = scan
      @sent = sent
    end

    def observe(inbound : Session::Inbound) : Nil
      @inbound = inbound
    end

    def starting(local : String, remote : String) : Nil
      @io.puts
      @io.puts "#{@brand.name.colorize.bold} #{File.basename(local).colorize.cyan} " \
               "#{"→".colorize.dark_gray} #{remote.colorize.cyan}"

      if @io.tty?
        @spinner.show { scan_status }
      else
        @io.puts "#{indent}#{"connecting and scanning both sides".colorize.dark_gray}"
      end
    end

    def progress(update : Session::TransferProgress) : Nil
      if update.confirmed.zero?
        @sent_before = @sent.try(&.bytes) || 0_i64
        @started = Time.instant
      end

      @progress = update
      @spinner.show { transfer_status }
    end

    def failed(message : String) : Nil
      clear_progress
      @errors.puts(@brand.prefix(message))
    end

    def warn(message : String) : Nil
      interrupted = @spinner.active?
      clear_progress
      @errors.puts(@brand.prefix(message))
      @spinner.resume if interrupted
    end

    def relay(line : String) : Nil
      interrupted = @spinner.active?
      clear_progress
      @errors.puts("#{indent}#{"remote".colorize.dark_gray} #{line}")
      @spinner.resume if interrupted
    end

    def ready(elapsed : Time::Span, watching : Int32) : Nil
      clear_progress

      @io.puts "#{indent}#{"ready".colorize.green.bold} #{"·".colorize.dark_gray} #{watching} " \
               "files in sync #{"·".colorize.dark_gray} #{format(elapsed)}"
      @io.puts "#{indent}#{"watching for changes, ctrl-c to stop".colorize.dark_gray}"
      @io.puts
    end

    def report(report : Session::Report, elapsed : Time::Span?) : Nil
      clear_progress

      if (halt = report.halt)
        @io.puts "#{indent}#{"halted".colorize.red.bold} #{halt.explain}"
        @io.puts "#{indent}#{"nothing was changed on either side".colorize.dark_gray}"
        @io.puts
        return
      end

      return preview(report) if @dry_run

      outgoing = report.remote_outcomes.select(&.applied?)
      incoming = report.local_outcomes.select(&.applied?)
      skipped = @verbose ? report.skipped : Array(Write::Outcome).new
      spoke = announce(report.conflicts)
      spoke = announce_troubles(report.troubles) || spoke

      return if !spoke && outgoing.empty? && incoming.empty? && skipped.empty?

      show("↑", Colorize::ColorANSI::Green, outgoing, report.remote_relocations)
      show("↓", Colorize::ColorANSI::Blue, incoming, report.local_relocations)

      unless skipped.empty?
        @io.puts "#{indent}#{"·".colorize.dark_gray} #{skipped.size} skipped".colorize.dark_gray

        skipped.each do |outcome|
          reason = outcome.explanation
          @io.puts "#{indent}  #{outcome.path} #{"(#{reason})".colorize.dark_gray}"
        end
      end

      if elapsed && !(outgoing.empty? && incoming.empty?)
        @io.puts "#{indent}#{"synced in #{format(elapsed)}".colorize.dark_gray}"
      end

      @io.puts
    end

    def scan_status : String
      scan = @scan
      return "connecting and scanning both sides" if scan.nil?
      return remote_status(scan) if scan.finished?
      return "scanning · #{scan.files} files" if scan.bytes.zero?

      "scanning · #{scan.files} files · #{mebibytes(scan.bytes.to_u64)} MiB hashed"
    end

    private def remote_status(scan : Progress) : String
      inbound = @inbound
      return "waiting for the remote · #{scan.files} files here" if inbound.nil?

      case (phase = inbound.phase)
      in Session::Inbound::Connecting
        "waiting for the remote · #{scan.files} files here"
      in Session::Inbound::RemoteScanning
        hashed =
          if phase.bytes.zero?
            ""
          else
            " · #{mebibytes(phase.bytes.to_u64)} MiB hashed"
          end
        "remote scanning · #{phase.files} files#{hashed}"
      in Session::Inbound::ReceivingTree
        receiving(inbound.received(phase), phase)
      end
    end

    private def receiving(received : Int64, phase : Session::Inbound::ReceivingTree) : String
      elapsed = (Time.instant - phase.since).total_seconds
      line = "receiving the remote tree · #{size_text(received)} of #{size_text(phase.expected)}"
      return line if elapsed < 0.5 || received.zero?

      rate = received / elapsed
      remaining = phase.expected - received
      line += " at #{size_text(rate.to_i64)}/s"
      line += " · about #{(remaining / rate).round.to_i} s left" if remaining > 0

      line
    end

    private def size_text(bytes : Int64) : String
      return "#{(bytes / 1024.0).round.to_i} KiB" if bytes < 1024 * 1024

      "#{(bytes / (1024.0 * 1024.0)).round(1)} MiB"
    end

    private def transfer_status : String
      update = @progress
      return "" if update.nil?

      case update.into
      in .remote? then "↑ sending #{update.confirmed}/#{update.total}#{throughput(update)}"
      in .local?  then "↓ receiving #{update.confirmed}/#{update.total}"
      end
    end

    private def throughput(update : Session::TransferProgress) : String
      sent = @sent
      return "" if sent.nil?

      sent_bytes = (sent.bytes - @sent_before).to_u64
      return "" if sent_bytes.zero?

      sent = mebibytes(sent_bytes)
      total = update.total_bytes
      volume = total ? "#{sent}/#{mebibytes(total)}" : sent
      elapsed = (Time.instant - @started).total_seconds
      rate =
        if elapsed > 0.5
          " at #{(sent_bytes / (1024.0 * 1024.0) / elapsed).round(1)} MiB/s"
        else
          ""
        end

      " · #{volume} MiB#{rate}"
    end

    private def mebibytes(bytes : UInt64) : String
      (bytes / (1024.0 * 1024.0)).round(1).to_s
    end

    # A conflict persists until someone acts on it, so say it once rather than
    # on every cycle, and say when it clears.
    private def announce(conflicts : Array(String)) : Bool
      current = conflicts.to_set
      fresh = (current - @announced).to_a.sort!
      cleared = (@announced - current).to_a.sort!

      if fresh.size > SUMMARISE_OVER && !@verbose
        location = busiest(fresh)
        @io.puts "#{indent}#{"!".colorize.yellow.bold} " \
                 "#{"#{fresh.size} conflicts".colorize.yellow} #{location.colorize.dark_gray}"
      else
        fresh.each do |root|
          @io.puts "#{indent}#{"!".colorize.yellow.bold} #{"conflict".colorize.yellow} #{root}"
        end
      end

      unless fresh.empty?
        advice = "both sides changed since the last sync; " \
                 "decide with --prefer-local and --prefer-remote globs"
        @io.puts "#{indent}  #{advice.colorize.dark_gray}"
      end

      if cleared.size > SUMMARISE_OVER && !@verbose
        @io.puts "#{indent}#{"✓".colorize.green} " \
                 "#{"#{cleared.size} conflicts resolved".colorize.dark_gray}"
      else
        cleared.each do |root|
          @io.puts "#{indent}#{"✓".colorize.green} #{"conflict resolved".colorize.dark_gray} " \
                   "#{root}"
        end
      end

      @announced = current
      !(fresh.empty? && cleared.empty?)
    end

    private def announce_troubles(troubles : Array(Core::Trouble)) : Bool
      current = Set(String).new(initial_capacity: troubles.size)
      spoke = false

      troubles.each do |trouble|
        key = "#{trouble.replica}:#{trouble.path}:#{trouble.reason}"
        current << key
        next if @announced_troubles.includes?(key)

        where = trouble.replica.remote? ? " on the remote" : ""
        @io.puts "#{indent}#{"!".colorize.yellow.bold} #{"cannot sync#{where}".colorize.yellow} " \
                 "#{trouble.path} " \
                 "#{"(#{trouble.reason}; it will not sync until this is fixed)".colorize.dark_gray}"
        spoke = true
      end

      @announced_troubles = current
      spoke
    end

    private def show(
      arrow : String,
      colour : Colorize::ColorANSI,
      outcomes : Array(Write::Outcome),
      relocations : Array(Core::Relocation),
    ) : Nil
      return if outcomes.empty? && relocations.empty?

      relocated = Set(String).new(initial_capacity: relocations.size * 2)
      relocations.each { |relocation| relocated << relocation.from << relocation.to }

      written = outcomes.select do |outcome|
        outcome.entry.is_a?(Core::File) && !relocated.includes?(outcome.path)
      end
      deleted = outcomes.select do |outcome|
        outcome.entry.nil? && !relocated.includes?(outcome.path)
      end

      if outcomes.size > SUMMARISE_OVER && !@verbose
        unless written.empty?
          @io.puts "#{indent}#{arrow.colorize(colour)} #{written.size} files " \
                   "#{summarise(written).colorize.dark_gray}"
        end

        unless deleted.empty?
          @io.puts "#{indent}#{arrow.colorize(colour)} " \
                   "#{"#{deleted.size} removed".colorize.dark_gray}"
        end

        unless relocations.empty?
          @io.puts "#{indent}#{arrow.colorize(colour)} " \
                   "#{"#{relocations.size} moved".colorize.dark_gray}"
        end

        return
      end

      relocations.each do |relocation|
        @io.puts "#{indent}#{arrow.colorize(colour)} #{relocation.from} " \
                 "#{"→".colorize.dark_gray} #{relocation.to}"
      end

      listed = (written + deleted).sort_by!(&.path)
      named = @verbose ? listed.size : NAMED_PATHS

      listed.first(named).each do |outcome|
        note = outcome.entry.nil? ? " #{"removed".colorize.dark_gray}" : ""
        @io.puts "#{indent}#{arrow.colorize(colour)} #{outcome.path}#{note}"
      end

      remaining = listed.size - named
      return if remaining <= 0

      @io.puts "#{indent}#{arrow.colorize(colour)} #{"and #{remaining} more".colorize.dark_gray}"
    end

    # name the directories rather than 250 individual files
    private def summarise(outcomes : Array(Write::Outcome)) : String
      busiest(outcomes.map(&.path))
    end

    private def busiest(paths : Array(String)) : String
      counts = Hash(String, Int32).new(0)
      paths.each { |path| counts[File.dirname(path)] += 1 }
      counts.delete(".")

      return "" if counts.empty?

      ranked = counts.to_a.sort_by! { |directory, count| {-count, directory} }
      shown = ranked.first(3).map(&.first)
      extra = ranked.size - shown.size
      suffix = extra > 0 ? " and #{extra} more" : ""

      "in #{shown.join(", ")}#{suffix}"
    end

    private def preview(report : Session::Report) : Nil
      outgoing = report.remote_outcomes
      incoming = report.local_outcomes

      if report.quiet?
        @io.puts "#{indent}#{"nothing to do".colorize.dark_gray}"
        return
      end

      @io.puts "#{indent}#{"dry run".colorize.yellow.bold} " \
               "#{"nothing will be changed".colorize.dark_gray}"

      listing("↑", Colorize::ColorANSI::Green, outgoing, report.remote_relocations)
      listing("↓", Colorize::ColorANSI::Blue, incoming, report.local_relocations)

      report.conflicts.each do |conflict|
        @io.puts "#{indent}#{"!".colorize.yellow} conflict #{conflict}"
      end
    end

    private def listing(
      arrow : String,
      colour : Colorize::ColorANSI,
      outcomes : Array(Write::Outcome),
      relocations : Array(Core::Relocation),
    ) : Nil
      return if outcomes.empty? && relocations.empty?

      relocations.each do |relocation|
        @io.puts "#{indent}#{arrow.colorize(colour)} #{"move  ".colorize.dark_gray} " \
                 "#{relocation.from} #{"→".colorize.dark_gray} #{relocation.to}"
      end

      outcomes.first(PREVIEW_PATHS).each do |outcome|
        @io.puts "#{indent}#{arrow.colorize(colour)} #{verb(outcome)} #{outcome.path}"
      end

      remaining = outcomes.size - PREVIEW_PATHS
      return if remaining <= 0

      @io.puts "#{indent}#{arrow.colorize(colour)} #{"and #{remaining} more".colorize.dark_gray}"
    end

    private def verb(outcome : Write::Outcome) : String
      entry = outcome.entry

      return "delete".colorize.red.to_s if entry.nil?
      return "mkdir ".colorize.dark_gray.to_s if entry.is_a?(Core::Directory)

      "write ".colorize.dark_gray.to_s
    end

    private def clear_progress : Nil
      @spinner.clear
    end

    private def format(elapsed : Time::Span) : String
      return "#{elapsed.total_milliseconds.round.to_i} ms" if elapsed.total_seconds < 1

      "#{elapsed.total_seconds.round(1)} s"
    end

    private def indent : String
      "  "
    end
  end
end
