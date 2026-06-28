module Lights
  class ScenesComponent < ApplicationComponent
    def initialize(light:)
      @light = light
    end

    private

    attr_reader :light

    # The bridge gives us only the scene NAME, not real colours, so derive a
    # stable two-stop gradient from the name for the preview swatch.
    def scene_gradient(name)
      sum = name.to_s.each_char.sum(&:ord)
      "linear-gradient(135deg, hsl(#{sum % 360} 70% 55%), hsl(#{(sum * 7) % 360} 65% 45%))"
    end
  end
end
