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

  def asset_name
    WeatherIcon.asset_name(icon, daytime)
  end
end
