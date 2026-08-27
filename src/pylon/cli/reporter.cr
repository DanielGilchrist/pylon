require "../session/session"

struct Pylon::CLI
  struct Reporter
    PREVIEW_LIMIT = 40

    def initialize(@io : IO, @verbose : Bool = false, @dry_run : Bool = false)
    end

    def report(report : Session::Report) : Nil
      if (halt = report.halt)
        @io.puts("halted: #{halt.explain}")
        @io.puts("  nothing was changed on either side; run again once it looks right")
        return
      end

      return if report.quiet? && !@verbose
      return preview(report) if @dry_run

      applied_to_local = report.local_outcomes.count(&.applied?)
      applied_to_remote = report.remote_outcomes.count(&.applied?)
      skipped = report.skipped

      parts = [] of String
      parts << "#{applied_to_remote} out" if applied_to_remote > 0
      parts << "#{applied_to_local} in" if applied_to_local > 0
      parts << "#{report.conflicts.size} conflicted" unless report.conflicts.empty?
      parts << "#{skipped.size} skipped" unless skipped.empty?

      @io.puts(parts.empty? ? "nothing to do" : parts.join(", "))

      report.conflicts.each { |conflict| @io.puts("  conflict  #{conflict.root}") }

      return unless @verbose

      skipped.each { |outcome| @io.puts("  skipped   #{outcome.path}  (#{outcome.problem})") }
    end

    private def preview(report : Session::Report) : Nil
      outgoing = report.remote_outcomes
      incoming = report.local_outcomes

      parts = [] of String
      parts << "#{outgoing.size} would go up" unless outgoing.empty?
      parts << "#{incoming.size} would come down" unless incoming.empty?
      parts << "#{report.conflicts.size} would conflict" unless report.conflicts.empty?

      @io.puts(parts.empty? ? "nothing to do" : "dry run: #{parts.join(", ")}")

      report.conflicts.each { |conflict| @io.puts("  conflict  #{conflict.root}") }

      list("up  ", outgoing)
      list("down", incoming)
    end

    private def verb(outcome : Write::Outcome) : String
      entry = outcome.entry

      return "delete " if entry.nil?
      return "mkdir  " if entry.kind.directory?

      "write  "
    end

    private def list(direction : String, outcomes : Array(Write::Outcome)) : Nil
      return if outcomes.empty? || !@verbose

      outcomes.first(PREVIEW_LIMIT).each do |outcome|
        @io.puts("  #{direction}  #{verb(outcome)} #{outcome.path}")
      end

      remaining = outcomes.size - PREVIEW_LIMIT
      @io.puts("  ... and #{remaining} more") if remaining > 0
    end
  end
end
