module Ameba::Rule::Style
  class TernaryWithNil < Base
    properties do
      description "Disallows ternaries with a nil branch"
    end

    MSG = "Write `value if condition` or `value unless condition` instead of a ternary with a " \
          "nil branch"

    def test(source : Source, node : Crystal::If) : Nil
      return unless node.ternary?
      return unless node.then.is_a?(Crystal::NilLiteral) || node.else.is_a?(Crystal::NilLiteral)

      issue_for node, MSG
    end
  end
end
