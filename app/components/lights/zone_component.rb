module Lights
  class ZoneComponent < ApplicationComponent
    def initialize(zone:, light_key:)
      @zone = zone
      @light_key = light_key
    end

    private

    attr_reader :zone, :light_key
  end
end
