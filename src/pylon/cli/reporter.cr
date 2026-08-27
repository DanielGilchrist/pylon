require "colorize"
require "../session/session"

struct Pylon::CLI
  struct Reporter
    NAMED_PATHS   =  6
    PREVIEW_PATHS = 40

    def initialize(@io : IO, @verbose : Bool = false, @dry_run : Bool = false)
      @progress_shown = false
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
      return if report.quiet?

      show("↑", :green, report.remote_outcomes.select(&.applied?))
      show("↓", :blue, report.local_outcomes.select(&.applied?))

      report.conflicts.each do |conflict|
        @io.puts "#{indent}#{"!".colorize.yellow.bold} #{"conflict".colorize.yellow} #{conflict.root} #{"— left alone on both sides".colorize.dark_gray}"
      end

      skipped = report.skipped
      return if skipped.empty?

      @io.puts "#{indent}#{"·".colorize.dark_gray} #{skipped.size} skipped#{@verbose ? "" : ", run with PYLON_VERBOSE=1 for detail"}".colorize.dark_gray

      return unless @verbose

      skipped.each { |outcome| @io.puts "#{indent}  #{outcome.path} #{"(#{outcome.problem})".colorize.dark_gray}" }
    end

    private def show(arrow : String, colour : Symbol, outcomes : Array(Write::Outcome)) : Nil
      return if outcomes.empty?

      named = @verbose ? outcomes.size : NAMED_PATHS

      outcomes.first(named).each do |outcome|
        @io.puts "#{indent}#{arrow.colorize(colour)} #{outcome.path}"
      end

      remaining = outcomes.size - named
      return if remaining <= 0

      @io.puts "#{indent}#{arrow.colorize(colour)} #{"and #{remaining} more".colorize.dark_gray}"
    end

    private def preview(report : Session::Report) : Nil
      outgoing = report.remote_outcomes
      incoming = report.local_outcomes

      if outgoing.empty? && incoming.empty? && report.conflicts.empty?
        @io.puts "#{indent}#{"nothing to do".colorize.dark_gray}"
        return
      end

      @io.puts "#{indent}#{"dry run".colorize.yellow.bold} #{"nothing will be changed".colorize.dark_gray}"

      listing("↑", :green, outgoing)
      listing("↓", :blue, incoming)

      report.conflicts.each do |conflict|
        @io.puts "#{indent}#{"!".colorize.yellow} conflict #{conflict.root}"
      end
    end

    private def listing(arrow : String, colour : Symbol, outcomes : Array(Write::Outcome)) : Nil
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
