WeatherDay = Data.define(:date, :records, :temp_min, :temp_max, :precip_sum, :solar_peak) do
  WEEKDAY_LABELS_DE = %w[Sonntag Montag Dienstag Mittwoch Donnerstag Freitag Samstag].freeze

  def self.from_records(date, records)
    temperatures = records.map(&:temperature).compact
    solar_values = records.map(&:solar).compact

    new(
      date: date,
      records: records,
      temp_min: temperatures.min,
      temp_max: temperatures.max,
      precip_sum: records.sum { |r| r.precipitation || 0 },
      solar_peak: solar_values.max
    )
  end

  # WeatherDay is built from forecast records (60-minute period). Convert
  # the raw kWh/m² peak to average W/m² for display.
  def solar_peak_w_per_m2
    solar_peak && solar_peak * 1000.0
  end

  def weekday_label
    WEEKDAY_LABELS_DE[date.wday]
  end

  def date_label
    date.strftime("%d.%m.")
  end
end
