require "weather_icon"

WeatherSegment = Data.define(:label, :hour_range, :records) do
  ICON_SEVERITY = %w[
    thunderstorm hail snow sleet rain wind fog cloudy partly-cloudy clear unknown
  ].freeze

  def expected_hours
    hour_range.size
  end

  def available_hours
    records.size
  end

  def complete?
    available_hours >= expected_hours
  end

  def empty?
    records.empty?
  end

  def partial?
    !empty? && !complete?
  end

  def temp_min
    records.map(&:temperature).compact.min
  end

  def temp_max
    records.map(&:temperature).compact.max
  end

  def precip_sum
    records.sum { |r| r.precipitation || 0 }
  end

  def avg_solar_w_per_m2
    values = records.filter_map(&:solar_w_per_m2)
    return nil if values.empty?
    values.sum / values.size
  end

  def all_night?
    records.any? && records.all? { |r| r.daytime == "night" }
  end

  def dominant_icon
    return "unknown" if records.empty?
    icons = records.map { |r| WeatherIcon.normalized_icon(r.icon) }
    icons.min_by { |i| ICON_SEVERITY.index(i) || ICON_SEVERITY.size }
  end

  def dominant_daytime
    target = dominant_icon
    record = records.find { |r| WeatherIcon.normalized_icon(r.icon) == target } || records.first
    record&.daytime || "day"
  end

  def asset_name
    WeatherIcon.asset_name(dominant_icon, dominant_daytime)
  end
end
