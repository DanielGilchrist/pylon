require "colorize"

require "../fibers"

struct Pylon::CLI
  class Spinner
    FRAMES   = {"⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"}
    INTERVAL = 80.milliseconds
    INDENT   = "  "

    HIDE_CURSOR = "\033[?25l"
    SHOW_CURSOR = "\033[?25h"

    @stop : Channel(Nil)? = nil

    def initialize(@io : IO) : Nil
      @supply = -> : String { "" }
      @done = Channel(Nil).new
      @restores_cursor = false
    end

    def show(text : String) : Nil
      show { text }
    end

    def show(&supplier : -> String) : Nil
      return unless @io.tty?

      @supply = supplier
      return if @stop

      stop = Channel(Nil).new
      @stop = stop
      restore_cursor_at_exit
      animate(stop)
    end

    def active? : Bool
      !@stop.nil?
    end

    def resume : Nil
      show(&@supply)
    end

    def clear : Nil
      stop = @stop
      return if stop.nil?

      @stop = nil
      stop.close
      @done.receive?
    end

    private def animate(stop : Channel(Nil)) : Nil
      Fibers.detach(:spinner) do
        @io.print HIDE_CURSOR
        frame = 0

        loop do
          select
          when stop.receive?
            break
          when timeout(INTERVAL)
            @io.print "\r\033[K#{INDENT}#{FRAMES[frame % FRAMES.size].colorize.cyan} " \
                      "#{@supply.call.colorize.dark_gray}"
            @io.flush
            frame += 1
          end
        end

        @io.print "\r\033[K#{SHOW_CURSOR}"
        @io.flush
        @done.send(nil)
      end
    end

    private def restore_cursor_at_exit : Nil
      return if @restores_cursor
      @restores_cursor = true

      io = @io
      at_exit { io.print(SHOW_CURSOR) if io.tty? }
    end
  end
end
