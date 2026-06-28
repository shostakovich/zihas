module Lights
  class LightCardComponent < ApplicationComponent
    def initialize(snapshot:)
      @snapshot = snapshot
    end

    private

    attr_reader :snapshot

    def light = snapshot.light

    def summary
      return "Aus" unless snapshot.on?
      "An · #{snapshot.white? ? 'Weiß' : 'Farbe'} · #{snapshot.brightness} %"
    end

    def chip
      return nil unless snapshot.on?
      { swatch: snapshot.color_hex || "#ffd9a0", label: "#{snapshot.brightness} %" }
    end
  end
end
