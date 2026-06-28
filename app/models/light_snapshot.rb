# Per-light view object for the "Schalten" tile and the detail page. Wraps a
# Light + its LightState; presentation (summary/chip) lives in the components.
class LightSnapshot
  attr_reader :light, :state

  def self.build_all(lights)
    lights = lights.to_a
    states = LightState.for_lights(lights.map(&:key))
    lights.map { |l| new(light: l, state: states[l.key]) }
  end

  def initialize(light:, state:)
    @light = light
    @state = state
  end

  def on?           = !!state&.on
  def brightness    = state&.brightness || 0
  def reachable?    = !!state&.reachable
  def color_temp_k  = state&.color_temp_k

  def rgb
    return nil unless state&.color_r
    [ state.color_r, state.color_g, state.color_b ]
  end

  def color_hex
    return nil unless rgb
    format("#%02x%02x%02x", *rgb)
  end

  # White when there is no RGB colour, or a positive colour temperature is set.
  def white? = color_temp_k.to_i.positive? || rgb.nil?

  def zone_lamp? = light.zone_lamp?

  def zones
    bits = state&.zone_states || {}
    light.zones.filter_map { |k|
      meta = Light::ZONE_META[k]
      next unless meta
      Lights::Zone.new(key: k, label: meta[:label], role: meta[:role], on: !!bits[k])
    }.sort_by { |z| z.role == "main" ? 0 : 1 }
  end
end
