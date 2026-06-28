# lib/govees/types.rb
require "dry/types"

module Govees
  # Liberal wire/device primitives. Deliberately separate from the strict,
  # UI-bound Lights::Types: a device may report brightness 0 or a scene kelvin
  # outside the slider range, and the Subscriber must accept those without
  # raising. (Be strict in what you send, liberal in what you accept.)
  module Types
    include Dry.Types()

    Bool         = Dry::Types["params.bool"]
    Brightness   = Dry::Types["params.integer"].constrained(gteq: 0, lteq: 100)
    Kelvin       = Dry::Types["params.integer"].constrained(gteq: 0)
    RgbComponent = Dry::Types["params.integer"].constrained(gteq: 0, lteq: 255)
    SceneName    = Dry::Types["params.string"].constrained(min_size: 1)
    ZoneName     = Dry::Types["params.string"].constrained(min_size: 1)
  end
end
