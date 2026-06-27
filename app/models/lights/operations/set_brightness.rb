module Lights
  module Operations
    class SetBrightness < Base
      def call(light:, params:, mqtt_config:)
        attrs = step coerce { Params::Brightness.new(value: params[:value]) }
        step via_commander { Govees::Commander.set_brightness(light, value: attrs.value, mqtt_config: mqtt_config) }
        Results::NoContent.new
      end
    end
  end
end
