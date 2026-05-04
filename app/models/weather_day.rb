WeatherDay = Data.define(:date, :records, :temp_min, :temp_max, :precip_sum, :solar_peak) do
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
end
