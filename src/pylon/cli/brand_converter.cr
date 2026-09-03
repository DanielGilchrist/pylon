require "kebab"
require "../brand"

struct Pylon::CLI
  module BrandConverter
    extend self

    def convert(input : String) : Brand | Kebab::Convert::Failure
      return Kebab::Convert.failure("it is blank", name: "brand") if input.blank?

      Brand.new(input)
    end
  end
end
