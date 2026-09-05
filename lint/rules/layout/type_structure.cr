require "./type_structure/rewrite"

module Ameba::Rule::Layout
  class TypeStructure < Base
    properties do
      description "Enforces one member order inside classes, structs, modules and enums"
    end

    ACCESSOR_MACROS = {
      "getter", "getter?", "getter!",
      "property", "property?", "property!",
      "setter",
      "delegate", "forward_missing_to",
      "def_equals", "def_hash", "def_equals_and_hash", "def_clone",
    }

    CLASS_STATE_MACROS = {
      "class_getter", "class_getter?", "class_getter!",
      "class_property", "class_property?", "class_property!",
      "class_setter",
    }

    enum Section
      EnumMembers
      Mixins
      Constants
      Aliases
      NestedTypes
      ClassVariables
      Macros
      PublicClassMethods
      ProtectedClassMethods
      PrivateClassMethods
      InstanceVariables
      Constructors
      Accessors
      PublicAbstractMethods
      PublicInstanceMethods
      ProtectedAbstractMethods
      ProtectedInstanceMethods
      PrivateAbstractMethods
      PrivateInstanceMethods
      PrivateNestedTypes

      def label : String
        case self
        in .enum_members?               then "enum members"
        in .mixins?                     then "mixins"
        in .constants?                  then "constants"
        in .aliases?                    then "aliases"
        in .nested_types?               then "nested types"
        in .class_variables?            then "class variables"
        in .macros?                     then "macros"
        in .public_class_methods?       then "public class methods"
        in .protected_class_methods?    then "protected class methods"
        in .private_class_methods?      then "private class methods"
        in .instance_variables?         then "instance variable declarations"
        in .constructors?               then "constructors"
        in .accessors?                  then "accessors"
        in .public_abstract_methods?    then "public abstract methods"
        in .public_instance_methods?    then "public instance methods"
        in .protected_abstract_methods? then "protected abstract methods"
        in .protected_instance_methods? then "protected instance methods"
        in .private_abstract_methods?   then "private abstract methods"
        in .private_instance_methods?   then "private instance methods"
        in .private_nested_types?       then "private nested types"
        end
      end
    end

    record Member, node : Crystal::ASTNode, section : Section, label : String

    def test(source : Source, node : Crystal::ClassDef | Crystal::ModuleDef) : Nil
      check(source, expressions(node.body))
    end

    def test(source : Source, node : Crystal::EnumDef) : Nil
      check(source, node.members)
    end

    private def check(source : Source, nodes : Array(Crystal::ASTNode)) : Nil
      members = nodes.compact_map { |node| member(node) }
      kept = ordered(members)
      return if kept.size == members.size

      rewrite = Rewrite.build(source.lines, nodes, members)

      members.each_with_index do |member, index|
        next if kept.includes?(index)
        next unless (message = message_for(members, kept, member, index))

        if (correction = rewrite)
          issue_for(member.node, message) { |corrector| correction.apply(corrector) }
          rewrite = nil
        else
          issue_for member.node, message
        end
      end
    end

    private def message_for(
      members : Array(Member),
      kept : Array(Int32),
      member : Member,
      index : Int32,
    ) : String?
      below = kept.reverse.find { |position| members[position].section < member.section }
      return too_early(member, members[below]) if below && below > index

      above = kept.find { |position| members[position].section > member.section }
      too_late(member, members[above]) if above
    end

    private def ordered(members : Array(Member)) : Array(Int32)
      weights = members.map { |member| members.count { |other| other.section == member.section } }
      best = weights.dup
      previous = Array(Int32?).new(members.size, nil)

      members.each_with_index do |member, index|
        index.times do |earlier|
          next if members[earlier].section > member.section
          next if best[earlier] + weights[index] <= best[index]

          best[index] = best[earlier] + weights[index]
          previous[index] = earlier
        end
      end

      kept = Array(Int32).new
      return kept unless (heaviest = best.max?)

      position = best.index(heaviest)
      while position
        kept.unshift(position)
        position = previous[position]
      end

      kept
    end

    private def expressions(body : Crystal::ASTNode) : Array(Crystal::ASTNode)
      body.is_a?(Crystal::Expressions) ? body.expressions : [body] of Crystal::ASTNode
    end

    private def member(outer : Crystal::ASTNode) : Member?
      node, visibility = unwrap(outer)
      section = classify(node, visibility)
      return unless section

      Member.new(node: outer, section: section, label: label(node))
    end

    private def unwrap(node : Crystal::ASTNode) : {Crystal::ASTNode, Crystal::Visibility}
      return {node.exp, node.modifier} if node.is_a?(Crystal::VisibilityModifier)

      {node, node.visibility}
    end

    private def classify(node : Crystal::ASTNode, visibility : Crystal::Visibility) : Section?
      case node
      when Crystal::Arg                      then Section::EnumMembers
      when Crystal::Include, Crystal::Extend then Section::Mixins
      when Crystal::Alias                    then Section::Aliases
      when Crystal::Assign                   then classify_assign(node)
      when Crystal::TypeDeclaration          then classify_declaration(node)
      when Crystal::ClassDef,
           Crystal::ModuleDef,
           Crystal::EnumDef,
           Crystal::AnnotationDef,
           Crystal::LibDef then nested_type(visibility)
      when Crystal::Macro   then Section::Macros
      when Crystal::MacroIf then classify_macro_if(node)
      when Crystal::Def     then classify_def(node, visibility)
      when Crystal::Call    then classify_call(node, visibility)
      end
    end

    private def classify_assign(node : Crystal::Assign) : Section?
      case node.target
      when Crystal::Path        then Section::Constants
      when Crystal::ClassVar    then Section::ClassVariables
      when Crystal::InstanceVar then Section::InstanceVariables
      end
    end

    private def classify_declaration(node : Crystal::TypeDeclaration) : Section?
      case node.var
      when Crystal::ClassVar    then Section::ClassVariables
      when Crystal::InstanceVar then Section::InstanceVariables
      end
    end

    private def classify_def(node : Crystal::Def, visibility : Crystal::Visibility) : Section
      return class_method(visibility) if node.receiver
      return Section::Constructors if constructor?(node)

      instance_method(visibility, abstract_method: node.abstract?)
    end

    private def constructor?(node : Crystal::Def) : Bool
      node.name.in?("initialize", "finalize")
    end

    private def classify_call(node : Crystal::Call, visibility : Crystal::Visibility) : Section?
      return if node.obj

      case node.name
      when "record"                 then nested_type(visibility)
      when .in?(CLASS_STATE_MACROS) then Section::ClassVariables
      when .in?(ACCESSOR_MACROS)    then accessor(visibility)
      end
    end

    private def classify_macro_if(node : Crystal::MacroIf) : Section?
      sections = Array(Section).new
      collect_sections(node.then, sections)
      collect_sections(node.else, sections)
      sections.min?
    end

    private def collect_sections(branch : Crystal::ASTNode, sections : Array(Section)) : Nil
      case branch
      when Crystal::MacroIf
        collect_sections(branch.then, sections)
        collect_sections(branch.else, sections)
      when Crystal::Expressions
        branch.expressions.each do |part|
          collect_sections(part, sections) if part.is_a?(Crystal::MacroIf)
        end
        classify_text(literal_text(branch.expressions), sections)
      when Crystal::MacroLiteral
        classify_text(branch.value, sections)
      end
    end

    private def literal_text(parts : Array(Crystal::ASTNode)) : String
      String.build do |io|
        parts.each { |part| io << part.value if part.is_a?(Crystal::MacroLiteral) }
      end
    end

    private def classify_text(text : String, sections : Array(Section)) : Nil
      return unless (parsed = parse(text))

      expressions(parsed).each do |expression|
        inner, inner_visibility = unwrap(expression)
        section = classify(inner, inner_visibility)
        sections << section if section
      end
    end

    private def parse(text : String) : Crystal::ASTNode?
      Crystal::Parser.parse(text)
    rescue Crystal::SyntaxException
      nil
    end

    private def nested_type(visibility : Crystal::Visibility) : Section
      visibility.private? ? Section::PrivateNestedTypes : Section::NestedTypes
    end

    private def class_method(visibility : Crystal::Visibility) : Section
      case visibility
      in .public?    then Section::PublicClassMethods
      in .protected? then Section::ProtectedClassMethods
      in .private?   then Section::PrivateClassMethods
      end
    end

    private def accessor(visibility : Crystal::Visibility) : Section
      return Section::Accessors if visibility.public?

      instance_method(visibility, abstract_method: false)
    end

    private def instance_method(visibility : Crystal::Visibility, abstract_method : Bool) : Section
      case visibility
      in .public?
        abstract_method ? Section::PublicAbstractMethods : Section::PublicInstanceMethods
      in .protected?
        abstract_method ? Section::ProtectedAbstractMethods : Section::ProtectedInstanceMethods
      in .private?
        abstract_method ? Section::PrivateAbstractMethods : Section::PrivateInstanceMethods
      end
    end

    private def label(node : Crystal::ASTNode) : String
      case node
      when Crystal::Def             then node.receiver ? "self.#{node.name}" : node.name
      when Crystal::Assign          then node.target.to_s
      when Crystal::TypeDeclaration then node.var.to_s
      when Crystal::Alias,
           Crystal::ClassDef,
           Crystal::ModuleDef,
           Crystal::EnumDef,
           Crystal::AnnotationDef,
           Crystal::LibDef then node.name.to_s
      when Crystal::Macro   then "macro #{node.name}"
      when Crystal::Arg     then node.name
      when Crystal::Include then "include #{node.name}"
      when Crystal::Extend  then "extend #{node.name}"
      when Crystal::Call    then call_label(node)
      else                       node.to_s.lines.first? || node.class.name
      end
    end

    private def call_label(node : Crystal::Call) : String
      return node.name unless (argument = node.args.first?)

      "#{node.name} #{argument_label(argument)}"
    end

    private def argument_label(node : Crystal::ASTNode) : String
      case node
      when Crystal::TypeDeclaration then node.var.to_s
      when Crystal::Assign          then node.target.to_s
      else                               node.to_s
      end
    end

    private def too_late(member : Member, anchor : Member) : String
      "#{member.section.label.capitalize} come before #{anchor.section.label}, so " \
      "`#{member.label}` belongs above `#{anchor.label}`"
    end

    private def too_early(member : Member, anchor : Member) : String
      "#{member.section.label.capitalize} come after #{anchor.section.label}, so " \
      "`#{member.label}` belongs below `#{anchor.label}`"
    end
  end
end
