module Lights
  class PowerComponent < ApplicationComponent
    def initialize(snapshot:)
      @snapshot = snapshot
    end

    private

    attr_reader :snapshot

    def light = snapshot.light
  end
end
