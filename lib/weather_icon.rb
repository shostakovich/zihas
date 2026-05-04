require "time"
require "tzinfo"

module WeatherIcon
  ICONS = %w[
    clear partly-cloudy cloudy fog wind rain sleet snow hail thunderstorm unknown
  ].freeze

  module_function

  def asset_name(icon, daytime)
    base = normalized_icon(icon)
    suffix = normalized_daytime(daytime)
    "weather_#{base.tr("-", "_")}_#{suffix}.webp"
  end

  def daytime_for(icon:, timestamp:, timezone:)
    return "day" if icon.to_s.end_with?("-day")
    return "night" if icon.to_s.end_with?("-night")

    tz = TZInfo::Timezone.get(timezone)
    local_time = tz.utc_to_local(timestamp.to_time.utc)
    (6...20).cover?(local_time.hour) ? "day" : "night"
  end

  def normalized_icon(icon)
    raw = icon.to_s
    raw = raw.delete_suffix("-day").delete_suffix("-night")
    ICONS.include?(raw) ? raw : "unknown"
  end

  def normalized_daytime(daytime)
    daytime.to_s == "night" ? "night" : "day"
  end
end
