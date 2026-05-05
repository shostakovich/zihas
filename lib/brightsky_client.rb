require "json"
require "net/http"
require "time"
require "uri"
require "weather_icon"

class BrightskyClient
  BASE_URL = "https://api.brightsky.dev"

  class Error < StandardError; end

  def initialize(lat:, lon:, timezone:, http_timeout: 5)
    @lat = lat
    @lon = lon
    @timezone = timezone
    @http_timeout = http_timeout
  end

  def current_weather
    body = get_json("/current_weather", lat: @lat, lon: @lon)
    normalize_current(body.fetch("weather"))
  end

  def weather_for_date(date)
    body = get_json("/weather", lat: @lat, lon: @lon, date: date.to_s)
    body.fetch("weather", []).map { |row| normalize_hourly(row) }
  rescue Error => e
    return :range_end if e.message.include?("404")
    raise
  end

  private

  def get_json(path, params)
    uri = URI(BASE_URL + path)
    uri.query = URI.encode_www_form(params)
    response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, read_timeout: @http_timeout, open_timeout: @http_timeout) do |http|
      http.get(uri)
    end
    raise Error, "Bright Sky HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)
    JSON.parse(response.body)
  rescue JSON::ParserError, KeyError, Net::OpenTimeout, Net::ReadTimeout, SocketError => e
    raise Error, e.message
  end

  def normalize_current(row)
    timestamp = Time.parse(row.fetch("timestamp"))
    {
      timestamp: timestamp,
      source_id: row["source_id"],
      precipitation: row["precipitation_10"],
      pressure_msl: row["pressure_msl"],
      sunshine: nil,
      temperature: row["temperature"],
      wind_direction: row["wind_direction_10"],
      wind_speed: row["wind_speed_10"],
      cloud_cover: row["cloud_cover"],
      dew_point: row["dew_point"],
      relative_humidity: row["relative_humidity"],
      visibility: row["visibility"],
      wind_gust_direction: row["wind_gust_direction_10"],
      wind_gust_speed: row["wind_gust_speed_10"],
      condition: row["condition"],
      precipitation_probability: nil,
      precipitation_probability_6h: nil,
      solar: row["solar_10"],
      icon: row["icon"],
      daytime: WeatherIcon.daytime_for(icon: row["icon"], timestamp: timestamp, lat: @lat, lon: @lon, timezone: @timezone)
    }
  end

  def normalize_hourly(row)
    timestamp = Time.parse(row.fetch("timestamp"))
    {
      timestamp: timestamp,
      source_id: row["source_id"],
      precipitation: row["precipitation"],
      pressure_msl: row["pressure_msl"],
      sunshine: row["sunshine"],
      temperature: row["temperature"],
      wind_direction: row["wind_direction"],
      wind_speed: row["wind_speed"],
      cloud_cover: row["cloud_cover"],
      dew_point: row["dew_point"],
      relative_humidity: row["relative_humidity"],
      visibility: row["visibility"],
      wind_gust_direction: row["wind_gust_direction"],
      wind_gust_speed: row["wind_gust_speed"],
      condition: row["condition"],
      precipitation_probability: row["precipitation_probability"],
      precipitation_probability_6h: row["precipitation_probability_6h"],
      solar: row["solar"],
      icon: row["icon"],
      daytime: WeatherIcon.daytime_for(icon: row["icon"], timestamp: timestamp, lat: @lat, lon: @lon, timezone: @timezone)
    }
  end
end
