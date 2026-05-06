class WeatherController < ApplicationController
  def index
    @current_weather = WeatherRecord.latest_current
    @today_weather = WeatherRecord.today_hourly
    @future_weather = WeatherRecord.future_days
  end
end
