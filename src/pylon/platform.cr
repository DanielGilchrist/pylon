module Pylon
  module Platform
    PLATFORMS = {"macos", "linux"}

    macro select(&block)
      {% statements = block.body.is_a?(Expressions) ? block.body.expressions : [block.body] %}
      {% branches = {} of String => ASTNode %}
      {% for statement in statements %}
        {% unless statement.is_a?(Call) && statement.block && statement.args.empty? && PLATFORMS.includes?(statement.name.stringify) %}
          {% raise "Platform.select takes exactly one `macos do ... end` and one `linux do ... end`, found #{statement}" %}
        {% end %}
        {% raise "Platform.select names #{statement.name} twice" if branches.keys.includes?(statement.name.stringify) %}
        {% branches[statement.name.stringify] = statement.block.body %}
      {% end %}
      {% for platform in PLATFORMS %}
        {% raise "Platform.select is missing the #{platform.id} branch" unless branches.keys.includes?(platform) %}
      {% end %}
      {% if flag?(:darwin) %}
        {{ branches["macos"] }}
      {% elsif flag?(:linux) %}
        {{ branches["linux"] }}
      {% else %}
        {% raise "pylon runs on macOS and Linux only, and this build targets neither" %}
      {% end %}
    end
  end
end
