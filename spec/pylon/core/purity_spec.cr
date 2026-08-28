require "../../spec_helper"

private FORBIDDEN = {
  /\bFile\.(?!match\?)/,
  /\bDir\./,
  /\bIO\b/,
  /\bSocket\b/,
  /\bProcess\./,
  /\bTime\./,
  /\bENV\b/,
  /\bRandom\b/,
}

describe "Pylon::Core purity" do
  it "performs no side effects" do
    offences = [] of String

    Dir.glob(File.join(__DIR__, "..", "..", "..", "src", "pylon", "core", "**", "*.cr")).each do |path|
      File.read_lines(path).each_with_index(1) do |line, number|
        FORBIDDEN.each do |pattern|
          next unless line.matches?(pattern)

          offences << "#{File.basename(path)}:#{number}: #{line.strip}"
        end
      end
    end

    offences.should be_empty,
      "the reconcile core must stay pure so it can be tested without a filesystem or network:\n#{offences.join("\n")}"
  end
end
