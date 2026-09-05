require "./changes"
require "./entry"
require "../problem"

module Pylon::Core
  struct Relocation
    record Extraction, changes : Changes, relocations : Array(Relocation)

    def self.parse(from : String, to : String, entry : Entry?) : Relocation | Problem
      return Problem.new("moves the sync root") if from.empty? || to.empty?
      return Problem.new("moves #{to.inspect} onto itself") if from == to
      return Problem.new("moves #{from.inspect} inside itself") if to.starts_with?("#{from}/")
      return Problem.new("moves #{from.inspect} out of itself") if from.starts_with?("#{to}/")

      case entry
      in Syncable                    then new(from, to, entry)
      in Nil, Untracked, Problematic then Problem.new("moves nothing at #{from.inspect}")
      end
    end

    def self.extract(changes : Changes) : Extraction
      deleted_at = Hash(Syncable, Int32).new

      changes.each_with_index do |change, index|
        old = change.old
        deleted_at[old] ||= index if change.new.nil? && old.is_a?(Syncable)
      end

      return Extraction.new(changes, Array(Relocation).new) if deleted_at.empty?

      relocations = Array(Relocation).new
      consumed = Set(Int32).new
      folded = nil

      changes.each_with_index do |change, index|
        new = change.new
        next unless change.old.nil? && new.is_a?(Syncable)

        delete_index = deleted_at[new]?
        next if delete_index.nil?

        from = changes[delete_index].path
        folded ||= folded_paths(changes)
        next unless unambiguous_case?(folded, from, change.path)

        case (relocation = parse(from, change.path, new))
        in Problem
          next
        in Relocation
          deleted_at.delete(new)
          consumed << delete_index << index
          relocations << relocation
        end
      end

      return Extraction.new(changes, relocations) if relocations.empty?

      remaining = Changes.new(initial_capacity: changes.size - consumed.size)
      changes.each_with_index do |change, index|
        remaining << change unless consumed.includes?(index)
      end

      Extraction.new(remaining, relocations)
    end

    private def self.folded_paths(changes : Changes) : Hash(String, Int32)
      folded = Hash(String, Int32).new(0)
      changes.each { |change| folded[change.path.downcase] += 1 }
      folded
    end

    private def self.unambiguous_case?(
      folded : Hash(String, Int32),
      from : String,
      to : String,
    ) : Bool
      folded[from.downcase] == 1 && folded[to.downcase] == 1
    end

    def initialize(@from : String, @to : String, @entry : Syncable) : Nil
    end

    getter from : String
    getter to : String
    getter entry : Syncable
  end
end
