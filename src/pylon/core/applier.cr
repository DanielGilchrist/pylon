module Pylon::Core
  module Applier
    extend self

    def apply(base : Entry?, changes : Array(Change)) : Entry?
      changes.reduce(base) do |tree, change|
        put(tree, segments(change.path), change.new)
      end
    end

    private def segments(path : String) : Array(String)
      path.empty? ? [] of String : path.split('/')
    end

    private def put(entry : Entry?, segments : Array(String), value : Entry?) : Entry?
      name = segments.first?
      return value if name.nil?

      directory = entry.nil? || !entry.directory? ? Entry.directory : entry
      contents = directory.contents.dup
      child = put(contents[name]?, segments[1..], value)

      if child.nil?
        contents.delete(name)
      else
        contents[name] = child
      end

      directory.with_contents(contents)
    end
  end
end
