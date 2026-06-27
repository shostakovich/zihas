module Lights
  module Operations
    class Turn < Base
      def call(light:, params:, mqtt_config:)
        attrs = step coerce { Params::Turn.new(on: params[:on]) }

        step via_commander {
          if light.zone_lamp?
            Govees::Commander.set_zone(light, zone: "powerSwitch", on: attrs.on, mqtt_config: mqtt_config)
          else
            Govees::Commander.turn(light, on: attrs.on, mqtt_config: mqtt_config)
          end
        }

        LightState.record_state(light.key, on: attrs.on)
        Results::Power.new(light: light)
      end
    end
  end
end
