module Lights
  module Operations
    class SetColor < Base
      def call(light:, params:, mqtt_config:)
        attrs = step coerce { Params::Color.new(r: params[:r], g: params[:g], b: params[:b]) }
        step via_commander { Govees::Commander.set_color(light, r: attrs.r, g: attrs.g, b: attrs.b, mqtt_config: mqtt_config) }
        Results::NoContent.new
      end
    end
  end
end
