require "colorize"
require "../session/session"

struct Pylon::CLI
  class Reporter
    NAMED_PATHS    =  6
    SUMMARISE_OVER = 12
    PREVIEW_PATHS  = 40

    def initialize(@io : IO, @verbose : Bool = false, @dry_run : Bool = false)
      @progress_shown = false
      @announced = Set(String).new
    end

    def starting(local : String, remote : String) : Nil
      @io.puts
      @io.puts "#{"pylon".colorize.bold} #{File.basename(local).colorize.cyan} #{"→".colorize.dark_gray} #{remote.colorize.cyan}"
      @io.puts "#{indent}#{"connecting and scanning both sides".colorize.dark_gray}"
    end

    def progress(done : Int32, total : Int32) : Nil
      return unless @io.tty?

      @progress_shown = true
      @io.print "\r#{indent}sending #{done}/#{total}".colorize.dark_gray
      @io.flush
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
        return
      end

      return preview(report) if @dry_run

      announce(report.conflicts)

      return if report.quiet?

      show("↑", Colorize::ColorANSI::Green, report.remote_outcomes.select(&.applied?))
      show("↓", Colorize::ColorANSI::Blue, report.local_outcomes.select(&.applied?))

      skipped = report.skipped
      return if skipped.empty?

      @io.puts "#{indent}#{"·".colorize.dark_gray} #{skipped.size} skipped#{@verbose ? "" : ", run with -v for detail"}".colorize.dark_gray

      return unless @verbose

      skipped.each do |outcome|
        reason = outcome.skipped.try(&.explain)
        @io.puts "#{indent}  #{outcome.path} #{"(#{reason})".colorize.dark_gray}"
      end
    end

    # A conflict persists until someone acts on it, so say it once rather than
    # on every cycle, and say when it clears.
    private def announce(conflicts : Array(Core::Conflict)) : Nil
      current = conflicts.map(&.root).to_set

      (current - @announced).to_a.sort!.each do |root|
        @io.puts "#{indent}#{"!".colorize.yellow.bold} #{"conflict".colorize.yellow} #{root}"
        @io.puts "#{indent}  #{"both sides changed it; delete the copy you do not want".colorize.dark_gray}"
      end

      (@announced - current).to_a.sort!.each do |root|
        @io.puts "#{indent}#{"✓".colorize.green} #{"conflict resolved".colorize.dark_gray} #{root}"
      end

      @announced = current
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
      counts = Hash(String, Int32).new(0)
      outcomes.each { |outcome| counts[File.dirname(outcome.path)] += 1 }
      counts.delete(".")

      return "" if counts.empty?

      busiest = counts.to_a.sort_by! { |directory, count| {-count, directory} }
      shown = busiest.first(3).map(&.first)
      extra = busiest.size - shown.size
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
      return unless @progress_shown

      @progress_shown = false
      @io.print "\r\033[K"
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
