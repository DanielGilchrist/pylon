module Pylon::Core
  module Paths
    extend self

    def join(path : String, name : String) : String
      path.empty? ? name : "#{path}/#{name}"
    end
  end
end
