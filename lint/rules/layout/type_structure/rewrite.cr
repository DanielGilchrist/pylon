module Ameba::Rule::Layout
  class TypeStructure < Base
    class Rewrite
      def self.build(lines : Array(String), nodes : Array(Crystal::ASTNode), members : Array(Member)) : Rewrite?
        slots = Array(Slot).new
        annotations = Array(Crystal::ASTNode).new

        nodes.each do |node|
          case node
          when Crystal::Nop
            next
          when Crystal::Annotation
            annotations << node
            next
          end

          member = members.find(&.node.same?(node))
          return unless member

          slot = Slot.build(lines, member, annotations.first?, slots.last?, slots.size)
          return unless slot

          slots << slot
          annotations.clear
        end

        return unless annotations.empty?
        return unless slots.size > 1
        return unless (first = slots.first?) && (last = slots.last?)

        slots.each_cons_pair do |slot, following|
          return unless blank?(lines, slot.last_line, following.first_line)
        end

        new(lines, slots, first.first_line, last.last_line)
      end

      private def self.blank?(lines : Array(String), last_line : Int32, first_line : Int32) : Bool
        lines[last_line...(first_line - 1)].all?(&.strip.empty?)
      end

      def initialize(@lines : Array(String), @slots : Array(Slot), @first_line : Int32, @last_line : Int32) : Nil
      end

      def apply(corrector : Source::Corrector) : Nil
        sorted = @slots.sort_by(&.section)

        content = String.build do |io|
          sorted.each_with_index do |slot, position|
            io << text(slot)

            if (following = sorted[position + 1]?)
              io << separator(slot, following)
            end
          end
        end

        corrector.replace({@first_line, 1}, {@last_line, @lines[@last_line - 1].size}, content)
      end

      private def text(slot : Slot) : String
        @lines[slot.first_line - 1..slot.last_line - 1].join('\n')
      end

      private def separator(slot : Slot, following : Slot) : String
        return "\n" * (following.first_line - slot.last_line) if following.index == slot.index + 1

        grouped?(slot, following) ? "\n" : "\n\n"
      end

      private def grouped?(slot : Slot, following : Slot) : Bool
        slot.section == following.section && slot.compact? && following.compact?
      end

      private record Slot, member : Member, first_line : Int32, last_line : Int32, index : Int32 do
        def self.build(lines : Array(String), member : Member, leading : Crystal::ASTNode?, previous : Slot?, index : Int32) : Slot?
          location = (leading || member.node).location
          end_location = member.node.end_location
          return unless location && end_location

          floor = previous ? previous.last_line : 0
          first_line = location.line_number

          while first_line - 1 > floor && lines[first_line - 2].strip.starts_with?('#')
            first_line -= 1
          end

          return unless first_line > floor
          return unless end_location.line_number >= first_line

          new(member: member, first_line: first_line, last_line: end_location.line_number, index: index)
        end

        def section : Section
          member.section
        end

        def compact? : Bool
          location = member.node.location
          end_location = member.node.end_location
          return false unless location && end_location

          location.line_number == end_location.line_number
        end
      end
    end
  end
end
