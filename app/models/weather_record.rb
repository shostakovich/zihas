require "weather_icon"

class WeatherRecord < ApplicationRecord
  KINDS = %w[current forecast historic].freeze
  DAYTIMES = %w[day night].freeze

  validates :kind, inclusion: { in: KINDS }
  validates :daytime, inclusion: { in: DAYTIMES }
  validates :timestamp, :lat, :lon, presence: true

  scope :for_location, ->(lat, lon) { where(lat: lat, lon: lon) }
  scope :current, -> { where(kind: "current") }
  scope :forecast, -> { where(kind: "forecast") }
  scope :historic, -> { where(kind: "historic") }

  def self.latest_current
    current.order(updated_at: :desc).first
  end

  def self.today_hourly(now: Time.current)
    where(kind: [ "forecast", "historic" ])
      .where(timestamp: now.beginning_of_hour..now.to_date.tomorrow.end_of_day)
      .order(:timestamp)
  end

  def self.future_days(today: Time.zone.today)
    forecast
      .where("timestamp > ?", today.end_of_day)
      .order(:timestamp)
      .group_by { |record| record.timestamp.to_date }
      .map { |date, records| WeatherDay.from_records(date, records) }
  end

  def asset_name
    WeatherIcon.asset_name(icon, daytime)
  end

  # Bright Sky reports `solar` as energy per area accumulated over the
  # source's period (kWh/m²). `current` covers 10 minutes; `forecast` and
  # `historic` cover 60 minutes. Convert to average power per area for
  # display so the column reads consistently as W/m² across kinds.
  def solar_w_per_m2
    return nil if solar.nil?
    period_minutes = kind == "current" ? 10 : 60
    solar * 1000.0 * (60.0 / period_minutes)
  end
end
