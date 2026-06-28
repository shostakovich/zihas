# app/models/lights/operations.rb
module Lights
  module Operations
    # command name (param) -> operation class
    ALL = {
      "turn"       => Turn,
      "zone"       => SetZone,
      "brightness" => SetBrightness,
      "color"      => SetColor,
      "color_temp" => SetColorTemp,
      "effect"     => SetScene,
      "scene"      => SetScene,
      "zone_undo"  => UndoZone
    }.freeze

    def self.[](name) = ALL[name]
  end
end
