module Lights
  class ColorPanelComponent < ApplicationComponent
    SWATCHES = %w[#ff4d4d #ff7a3d #ffd43b #43d97f #22b8cf #4d7cff #7c5cff #ff6bd6].freeze

    def initialize(snapshot:)
      @snapshot = snapshot
    end

    private

    attr_reader :snapshot
  end
end
