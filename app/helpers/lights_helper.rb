module LightsHelper
  # govee2mqtt gives us only the scene NAME, not real colours, so derive a
  # stable two-stop gradient from the name for the preview swatch.
  def scene_gradient(name)
    sum = name.to_s.each_char.sum(&:ord)
    "linear-gradient(135deg, hsl(#{sum % 360} 70% 55%), hsl(#{(sum * 7) % 360} 65% 45%))"
  end
end
