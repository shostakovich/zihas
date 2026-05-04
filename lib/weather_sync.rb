require "brightsky_client"
require "config_loader"

class WeatherSync
  FORECAST_MAX_DAYS = 10

  def self.from_app_config
    config = ConfigLoader.load(Rails.root.join("config", Rails.env.test? ? "ziwoas.test.yml" : "ziwoas.yml").to_s)
    return nil if config.weather.nil?

    new(
      config: config,
      client: BrightskyClient.new(lat: config.weather.lat, lon: config.weather.lon, timezone: config.timezone)
    )
  end

  def initialize(config:, client:)
    @config = config
    @client = client
  end

  def sync_current
    row = @client.current_weather
    WeatherRecord.where(kind: "current", lat: lat, lon: lon).delete_all
    create_record!("current", row)
  end

  def sync_today(today: Date.current)
    rows = @client.weather_for_date(today)
    return if rows == :range_end
    rows.each { |row| upsert_record!("forecast", row) }
  end

  def sync_forecast(today: Date.current, max_days: FORECAST_MAX_DAYS)
    1.upto(max_days) do |offset|
      rows = @client.weather_for_date(today + offset)
      break if rows == :range_end || rows.empty?
      rows.each { |row| upsert_record!("forecast", row) }
    end
  end

  def sync_historic_date(date)
    rows = @client.weather_for_date(date)
    return if rows == :range_end
    rows.each do |row|
      WeatherRecord.where(kind: "forecast", lat: lat, lon: lon, timestamp: row.fetch(:timestamp)).delete_all
      upsert_record!("historic", row)
    end
  end

  def backfill_historic_from_daily_totals
    DailyTotal.distinct.pluck(:date).sort.each do |date_s|
      date = Date.parse(date_s)
      next if historic_complete?(date)
      sync_historic_date(date)
    end
  end

  private

  def lat = @config.weather.lat
  def lon = @config.weather.lon

  def create_record!(kind, row)
    WeatherRecord.create!(record_attrs(kind, row))
  end

  def upsert_record!(kind, row)
    record = WeatherRecord.find_or_initialize_by(kind: kind, lat: lat, lon: lon, timestamp: row.fetch(:timestamp))
    record.update!(record_attrs(kind, row))
  end

  def record_attrs(kind, row)
    row.merge(kind: kind, lat: lat, lon: lon)
  end

  def historic_complete?(date)
    WeatherRecord.where(kind: "historic", lat: lat, lon: lon, timestamp: date.beginning_of_day..date.end_of_day).count >= 24
  end
end
