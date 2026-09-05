require "kebab"
require "../problem"
require "../session/server"

struct Pylon::CLI
  @[Kebab::Command(
    summary: "Run the remote end of a sync. The client starts this over ssh and configures it",
  )]
  struct Remote
    include Kebab::Parseable

    def run : Nil
      IO::FileDescriptor.set_blocking(STDIN.fd, false)
      IO::FileDescriptor.set_blocking(STDOUT.fd, false)

      case (accepted = Session::Server.accept(STDIN, STDOUT, STDERR))
      in Session::Server
        accepted.run
      in Problem
        STDERR.puts(accepted.reason)
        exit(1)
      end
    end
  end
end
