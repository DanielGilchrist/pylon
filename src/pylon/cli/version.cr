require "kebab"

struct Pylon::CLI
  @[Kebab::Command(summary: "Print the version and exit")]
  struct Version
    include Kebab::Parseable

    def run : Nil
      puts VERSION
    end
  end
end
