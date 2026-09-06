module Pylon
  module Platform
    FLAGS = {macos: :darwin, linux: :linux}

    macro skip_file_unless(platform)
      {% unless platform.is_a?(SymbolLiteral) %}
        {% raise "Platform.skip_file_unless takes a symbol, got #{platform}" %}
      {% end %}
      {% unless FLAGS.keys.includes?(platform.id) %}
        {% raise "Platform.skip_file_unless expects one of #{FLAGS.keys.join(", ").id}, " \
                 "got #{platform}" %}
      {% end %}
      {% skip_file unless flag?(FLAGS[platform]) %}
    end

    macro select(&block)
      {% statements = block.body.is_a?(Expressions) ? block.body.expressions : [block.body] %}
      {% names = FLAGS.keys.map(&.id) %}
      {% branches = {} of MacroId => ASTNode %}
      {% for statement in statements %}
        {% branch = statement.is_a?(Call) && statement.block && statement.args.empty? %}
        {% unless branch && names.includes?(statement.name) %}
          {% raise "Platform.select takes one block per platform (#{names.join(", ").id}), " \
                   "found #{statement}" %}
        {% end %}
        {% if branches.keys.includes?(statement.name) %}
          {% raise "Platform.select names #{statement.name} twice" %}
        {% end %}
        {% branches[statement.name] = statement.block.body %}
      {% end %}
      {% for name in names %}
        {% unless branches.keys.includes?(name) %}
          {% raise "Platform.select is missing the #{name} branch" %}
        {% end %}
      {% end %}
      {% current = names.find { |name| flag?(FLAGS[name]) } %}
      {% unless current %}
        {% raise "pylon runs on #{names.join(" and ").id} only, and this build targets neither" %}
      {% end %}
      {{ branches[current] }}
    end
  end
end
