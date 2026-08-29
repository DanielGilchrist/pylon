require "colorize"
require "../session/session"
require "./spinner"

struct Pylon::CLI
  class Reporter
    NAMED_PATHS    =  6
    SUMMARISE_OVER = 12
    PREVIEW_PATHS  = 40

    @progress : Session::Progress? = nil
    @scan : Scan::Tally? = nil

    def initialize(@io : IO, @verbose : Bool = false, @dry_run : Bool = false)
      @announced = Set(String).new
      @spinner = Spinner.new(@io)
      @streamed = 0
      @streamed_bytes = 0_u64
      @started = Time.instant
    end

    def observe(scan : Scan::Tally) : Nil
      @scan = scan
    end

    def starting(local : String, remote : String) : Nil
      @io.puts
      @io.puts "#{"pylon".colorize.bold} #{File.basename(local).colorize.cyan} #{"→".colorize.dark_gray} #{remote.colorize.cyan}"

      if @io.tty?
        @spinner.show { scan_status }
      else
        @io.puts "#{indent}#{"connecting and scanning both sides".colorize.dark_gray}"
      end
    end

    private def scan_status : String
      scan = @scan
      return "connecting and scanning both sides" if scan.nil?

      if scan.finished?
        "waiting for the remote scan · #{scan.files} files here"
      elsif scan.hashed_bytes.zero?
        "scanning · #{scan.files} files"
      else
        "scanning · #{scan.files} files · #{mebibytes(scan.hashed_bytes.to_u64)} MiB hashed"
      end
    end

    def progress(update : Session::Progress) : Nil
      if update.confirmed.zero?
        @streamed = 0
        @streamed_bytes = 0_u64
        @started = Time.instant
      end

      @progress = update
      refresh
    end

    def streamed(bytes : UInt64) : Nil
      @streamed += 1
      @streamed_bytes += bytes
      refresh
    end

    private def refresh : Nil
      update = @progress
      return if update.nil?

      case update.direction
      in .to_remote?
        sent = Math.max(@streamed, update.confirmed)
        @spinner.show("↑ sending #{sent}/#{update.total}#{throughput} · #{update.confirmed} written on the remote")
      in .to_local?
        @spinner.show("↓ receiving #{update.confirmed}/#{update.total}")
      end
    end

    private def throughput : String
      return "" if @streamed_bytes.zero?

      sent = mebibytes(@streamed_bytes)
      total = @progress.try(&.total_bytes)
      volume = total ? "#{sent}/#{mebibytes(total)}" : sent
      elapsed = (Time.instant - @started).total_seconds
      rate = elapsed > 0.5 ? " at #{(@streamed_bytes / (1024.0 * 1024.0) / elapsed).round(1)} MiB/s" : ""

      " · #{volume} MiB#{rate}"
    end

    private def mebibytes(bytes : UInt64) : String
      (bytes / (1024.0 * 1024.0)).round(1).to_s
    end

    def ready(elapsed : Time::Span, watching : Int32) : Nil
      clear_progress

      @io.puts "#{indent}#{"ready".colorize.green.bold} #{"·".colorize.dark_gray} #{watching} files in sync #{"·".colorize.dark_gray} #{format(elapsed)}"
      @io.puts "#{indent}#{"watching for changes, ctrl-c to stop".colorize.dark_gray}"
      @io.puts
    end

    def report(report : Session::Report) : Nil
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
      skipped = @verbose ? report.skipped : [] of Write::Outcome
      spoke = announce(report.conflicts)

      return unless spoke || !outgoing.empty? || !incoming.empty? || !skipped.empty?

      show("↑", Colorize::ColorANSI::Green, outgoing)
      show("↓", Colorize::ColorANSI::Blue, incoming)

      unless skipped.empty?
        @io.puts "#{indent}#{"·".colorize.dark_gray} #{skipped.size} skipped".colorize.dark_gray

        skipped.each do |outcome|
          reason = outcome.skipped.try(&.explain)
          @io.puts "#{indent}  #{outcome.path} #{"(#{reason})".colorize.dark_gray}"
        end
      end

      @io.puts
    end

    # A conflict persists until someone acts on it, so say it once rather than
    # on every cycle, and say when it clears.
    private def announce(conflicts : Array(Core::Conflict)) : Bool
      current = conflicts.map(&.root).to_set
      fresh = (current - @announced).to_a.sort!
      cleared = (@announced - current).to_a.sort!

      if fresh.size > SUMMARISE_OVER && !@verbose
        location = busiest(fresh)
        @io.puts "#{indent}#{"!".colorize.yellow.bold} #{"#{fresh.size} conflicts".colorize.yellow} #{location.colorize.dark_gray}"
      else
        fresh.each do |root|
          @io.puts "#{indent}#{"!".colorize.yellow.bold} #{"conflict".colorize.yellow} #{root}"
        end
      end

      unless fresh.empty?
        @io.puts "#{indent}  #{"both sides changed since the last sync; decide with --prefer-local and --prefer-remote globs".colorize.dark_gray}"
      end

      if cleared.size > SUMMARISE_OVER && !@verbose
        @io.puts "#{indent}#{"✓".colorize.green} #{"#{cleared.size} conflicts resolved".colorize.dark_gray}"
      else
        cleared.each do |root|
          @io.puts "#{indent}#{"✓".colorize.green} #{"conflict resolved".colorize.dark_gray} #{root}"
        end
      end

      @announced = current
      !(fresh.empty? && cleared.empty?)
    end

    private def show(arrow : String, colour : Colorize::ColorANSI, outcomes : Array(Write::Outcome)) : Nil
      return if outcomes.empty?

      written = outcomes.select { |outcome| outcome.entry.try(&.kind.file?) }
      deleted = outcomes.select { |outcome| outcome.entry.nil? }

      if outcomes.size > SUMMARISE_OVER && !@verbose
        unless written.empty?
          @io.puts "#{indent}#{arrow.colorize(colour)} #{written.size} files #{summarise(written).colorize.dark_gray}"
        end

        unless deleted.empty?
          @io.puts "#{indent}#{arrow.colorize(colour)} #{"#{deleted.size} removed".colorize.dark_gray}"
        end

        return
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

      if outgoing.empty? && incoming.empty? && report.conflicts.empty?
        @io.puts "#{indent}#{"nothing to do".colorize.dark_gray}"
        return
      end

      @io.puts "#{indent}#{"dry run".colorize.yellow.bold} #{"nothing will be changed".colorize.dark_gray}"

      listing("↑", Colorize::ColorANSI::Green, outgoing)
      listing("↓", Colorize::ColorANSI::Blue, incoming)

      report.conflicts.each do |conflict|
        @io.puts "#{indent}#{"!".colorize.yellow} conflict #{conflict.root}"
      end
    end

    private def listing(arrow : String, colour : Colorize::ColorANSI, outcomes : Array(Write::Outcome)) : Nil
      return if outcomes.empty?

      outcomes.first(PREVIEW_PATHS).each do |outcome|
        @io.puts "#{indent}#{arrow.colorize(colour)} #{verb(outcome)} #{outcome.path}"
      end

      remaining = outcomes.size - PREVIEW_PATHS
      @io.puts "#{indent}#{arrow.colorize(colour)} #{"and #{remaining} more".colorize.dark_gray}" if remaining > 0
    end

    private def verb(outcome : Write::Outcome) : String
      entry = outcome.entry

      return "delete".colorize.red.to_s if entry.nil?
      return "mkdir ".colorize.dark_gray.to_s if entry.kind.directory?

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
