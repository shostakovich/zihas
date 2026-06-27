module Lights
  module Types
    include Dry.Types()

    Bool         = Dry::Types["params.bool"]
    Brightness   = Dry::Types["params.integer"].constrained(gteq: 1, lteq: 100)
    Kelvin       = Dry::Types["params.integer"].constrained(gteq: 2700, lteq: 6500)
    RgbComponent = Dry::Types["params.integer"].constrained(gteq: 0, lteq: 255)
    SceneName    = Dry::Types["params.string"].constrained(min_size: 1)
  end
end
