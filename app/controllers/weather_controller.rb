class WeatherController < ApplicationController
  def index
    @current_weather = WeatherRecord.current.order(updated_at: :desc).first
    @today_weather = WeatherRecord
      .where(timestamp: Time.zone.today.all_day)
      .where(kind: [ "forecast", "historic" ])
      .order(:timestamp)
    @future_weather = WeatherRecord
      .where(kind: "forecast")
      .where("timestamp > ?", Time.zone.today.end_of_day)
      .order(:timestamp)
      .group_by { |record| record.timestamp.to_date }
      .map { |date, records| WeatherDay.from_records(date, records) }
  end
end
