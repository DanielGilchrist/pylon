require "../session/session"

struct Pylon::CLI
  struct Reporter
    def initialize(@io : IO, @verbose : Bool = false)
    end

    def report(report : Session::Report) : Nil
      if (halt = report.halt)
        @io.puts("halted: #{halt.explain}")
        @io.puts("  nothing was changed on either side; run again once it looks right")
        return
      end

      return if report.quiet? && !@verbose

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

      skipped.each do |outcome|
        @io.puts("  skipped   #{outcome.path}  (#{outcome.problem})")
      end
    end
  end
end
