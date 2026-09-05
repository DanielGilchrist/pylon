require "spec"
require "ameba"
require "ameba/spec/support"
require "../../rules/style/ternary_with_nil"

describe Ameba::Rule::Style::TernaryWithNil do
  subject = Ameba::Rule::Style::TernaryWithNil.new

  it "passes a ternary whose branches both carry a value" do
    expect_no_issues subject, <<-CRYSTAL
      label = ready ? "ready" : "waiting"
      CRYSTAL
  end

  it "passes the conditional forms" do
    expect_no_issues subject, <<-CRYSTAL
      digest = entry.digest if entry.is_a?(File)
      buffer unless failed
      known = fingerprint(tree) if tree
      CRYSTAL
  end

  it "passes a full if expression with a nil branch" do
    expect_no_issues subject, <<-CRYSTAL
      if ready
        nil
      else
        compute
      end
      CRYSTAL
  end

  it "flags a ternary that yields nil when the condition holds" do
    expect_issue subject, <<-CRYSTAL
      value = failed ? nil : buffer
            # ^^^^^^^^^^^^^^^^^^^^^ error: Write `value if condition` or `value unless condition` instead of a ternary with a nil branch
      CRYSTAL
  end

  it "flags a ternary that yields nil when the condition fails" do
    expect_issue subject, <<-CRYSTAL
      digest = entry.is_a?(File) ? entry.digest : nil
             # ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ error: Write `value if condition` or `value unless condition` instead of a ternary with a nil branch
      CRYSTAL
  end
end
