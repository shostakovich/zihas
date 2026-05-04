class DashboardController < ApplicationController
  def index
    current_weather = WeatherRecord.current.order(updated_at: :desc).first
    @dashboard_weather_asset = current_weather&.asset_name || "icon_sonne.webp"
    @dashboard_weather_alt = current_weather&.icon.presence || "Sonne"
  end
end
