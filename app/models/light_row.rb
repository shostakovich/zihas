# Per-light view model for the "Schalten" tab tile and the detail page.
class LightRow
  attr_reader :light, :state

  def self.build_all(lights)
    lights = lights.to_a
    states = LightState.where(light_key: lights.map(&:key)).index_by(&:light_key)
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

  def default_tab = (on? && !white?) ? "color" : "white"

  def summary
    return "Aus" unless on?
    "An · #{white? ? 'Weiß' : 'Farbe'} · #{brightness} %"
  end

  def chip
    return nil unless on?
    { swatch: color_hex || "#ffd9a0", label: "#{brightness} %" }
  end
end
