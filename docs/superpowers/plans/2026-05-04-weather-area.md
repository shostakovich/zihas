# Weather Area Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Bright-Sky-backed weather area with current weather, today's hourly preview, future forecast, historic backfill, and dashboard weather icons.

**Architecture:** Store all weather in one `weather_records` table with `kind` values `current`, `forecast`, and `historic`. Keep API access in `BrightskyClient`, persistence rules in `WeatherSync`, and presentation helpers in `WeatherIcon`. Jobs call the service layer; controllers only read persisted data.

**Tech Stack:** Rails 8.1, Minitest, WebMock, Solid Queue recurring jobs, SQLite, ERB, importmap/Stimulus-free server-rendered weather UI, asset pipeline WebP images.

---

## File Structure

- Modify `lib/config_loader.rb`: add optional `WeatherCfg` and validation.
- Modify `config/ziwoas.example.yml`: document `weather.lat` and `weather.lon`.
- Create `db/migrate/20260504000000_create_weather_records.rb`: weather table and indexes.
- Create `app/models/weather_record.rb`: enum-like validations and query helpers.
- Create `lib/weather_icon.rb`: Bright-Sky icon + day/night to asset filename mapping.
- Create `lib/brightsky_client.rb`: HTTP client for `/weather` and `/current_weather`.
- Create `lib/weather_sync.rb`: database upsert and backfill orchestration.
- Create `app/jobs/weather_current_job.rb`, `app/jobs/weather_today_job.rb`, `app/jobs/weather_forecast_job.rb`, `app/jobs/weather_historic_job.rb`.
- Modify `config/recurring.yml`: register recurring weather jobs.
- Create `app/controllers/weather_controller.rb`.
- Create `app/views/weather/index.html.erb`.
- Modify `config/routes.rb`: add `/weather`.
- Modify `app/views/layouts/application.html.erb`: add nav link.
- Modify `app/controllers/dashboard_controller.rb`: expose current weather asset.
- Modify `app/views/dashboard/index.html.erb`: use current weather icon in hero and PV node.
- Modify `app/assets/stylesheets/application.css`: weather page styles.
- Add processed assets to `app/assets/images/weather_*.webp`.
- Create tests in `test/test_config_loader.rb`, `test/models/weather_record_test.rb`, `test/test_weather_icon.rb`, `test/test_brightsky_client.rb`, `test/test_weather_sync.rb`, `test/jobs/weather_*_job_test.rb`, `test/controllers/weather_controller_test.rb`, `test/controllers/dashboard_controller_test.rb`.

## Task 1: Weather Configuration

**Files:**
- Modify: `lib/config_loader.rb`
- Modify: `config/ziwoas.example.yml`
- Test: `test/test_config_loader.rb`

- [ ] **Step 1: Add failing config tests**

Append these tests to `ConfigLoaderTest`:

```ruby
def test_loads_optional_weather_config
  cfg = load_yaml(valid_yaml + <<~YAML)
    weather:
      lat: 52.52
      lon: 13.405
  YAML

  assert_in_delta 52.52, cfg.weather.lat
  assert_in_delta 13.405, cfg.weather.lon
end

def test_weather_config_is_optional
  cfg = load_yaml(valid_yaml)

  assert_nil cfg.weather
end

def test_rejects_invalid_weather_latitude
  err = assert_raises(ConfigLoader::Error) do
    load_yaml(valid_yaml + <<~YAML)
      weather:
        lat: 100
        lon: 13.405
    YAML
  end

  assert_match(/weather\.lat/i, err.message)
end

def test_rejects_invalid_weather_longitude
  err = assert_raises(ConfigLoader::Error) do
    load_yaml(valid_yaml + <<~YAML)
      weather:
        lat: 52.52
        lon: 200
    YAML
  end

  assert_match(/weather\.lon/i, err.message)
end

def test_rejects_missing_weather_latitude
  err = assert_raises(ConfigLoader::Error) do
    load_yaml(valid_yaml + <<~YAML)
      weather:
        lon: 13.405
    YAML
  end

  assert_match(/weather\.lat/i, err.message)
end

def test_rejects_non_numeric_weather_longitude
  err = assert_raises(ConfigLoader::Error) do
    load_yaml(valid_yaml + <<~YAML)
      weather:
        lat: 52.52
        lon: east
    YAML
  end

  assert_match(/weather\.lon/i, err.message)
end
```

- [ ] **Step 2: Run the config tests and verify failure**

Run: `rtk bin/rails test test/test_config_loader.rb`

Expected: failures because `cfg.weather` is not defined.

- [ ] **Step 3: Implement config support**

In `lib/config_loader.rb`, add:

```ruby
WeatherCfg = Struct.new(:lat, :lon, keyword_init: true)
```

Add `:weather` to the `Config` struct. In `build`, create `weather = build_weather(@raw["weather"])` and pass `weather: weather` into `Config.new`.

Add this private method:

```ruby
def build_weather(h)
  return nil if h.nil?
  h = require_hash(h, "weather")
  lat = require_coordinate(h["lat"], "weather.lat")
  lon = require_coordinate(h["lon"], "weather.lon")
  raise Error, "weather.lat must be between -90 and 90" unless (-90..90).cover?(lat)
  raise Error, "weather.lon must be between -180 and 180" unless (-180..180).cover?(lon)

  WeatherCfg.new(lat: lat, lon: lon)
end

def require_coordinate(v, key)
  raise Error, "#{key} must be a number" if v.nil? || v.to_s.empty?
  Float(v)
rescue ArgumentError, TypeError
  raise Error, "#{key} must be a number"
end
```

Do not use `to_f` before validation; missing or non-numeric coordinates must
raise `ConfigLoader::Error`.

- [ ] **Step 4: Document example config**

In `config/ziwoas.example.yml`, add after `timezone`:

```yaml
weather:
  lat: 52.52
  lon: 13.405
```

- [ ] **Step 5: Run tests and commit**

Run: `rtk bin/rails test test/test_config_loader.rb`

Expected: all tests pass.

Commit:

```bash
rtk git add lib/config_loader.rb config/ziwoas.example.yml test/test_config_loader.rb
rtk git commit -m "Add weather configuration"
```

## Task 2: Weather Table, Model, and Icon Mapping

**Files:**
- Create: `db/migrate/20260504000000_create_weather_records.rb`
- Create: `app/models/weather_record.rb`
- Create: `lib/weather_icon.rb`
- Test: `test/models/weather_record_test.rb`
- Test: `test/test_weather_icon.rb`

- [ ] **Step 1: Add model and icon tests**

Create `test/test_weather_icon.rb`:

```ruby
require "test_helper"
require "weather_icon"

class WeatherIconTest < Minitest::Test
  def test_maps_bright_sky_day_and_night_icons
    assert_equal "weather_clear_day.webp", WeatherIcon.asset_name("clear-day", "day")
    assert_equal "weather_clear_night.webp", WeatherIcon.asset_name("clear-night", "night")
    assert_equal "weather_partly_cloudy_day.webp", WeatherIcon.asset_name("partly-cloudy-day", "day")
    assert_equal "weather_partly_cloudy_night.webp", WeatherIcon.asset_name("partly-cloudy-night", "night")
  end

  def test_maps_neutral_icons_with_daytime
    assert_equal "weather_rain_day.webp", WeatherIcon.asset_name("rain", "day")
    assert_equal "weather_rain_night.webp", WeatherIcon.asset_name("rain", "night")
  end

  def test_falls_back_for_unknown_icon
    assert_equal "weather_unknown_day.webp", WeatherIcon.asset_name("not-real", "day")
    assert_equal "weather_unknown_night.webp", WeatherIcon.asset_name(nil, "night")
  end

  def test_derives_daytime_from_icon_suffix
    assert_equal "day", WeatherIcon.daytime_for(icon: "clear-day", timestamp: Time.utc(2026, 5, 4, 22), timezone: "Europe/Berlin")
    assert_equal "night", WeatherIcon.daytime_for(icon: "clear-night", timestamp: Time.utc(2026, 5, 4, 12), timezone: "Europe/Berlin")
  end

  def test_derives_daytime_from_local_hour_for_neutral_icon
    assert_equal "day", WeatherIcon.daytime_for(icon: "rain", timestamp: Time.utc(2026, 5, 4, 10), timezone: "Europe/Berlin")
    assert_equal "night", WeatherIcon.daytime_for(icon: "rain", timestamp: Time.utc(2026, 5, 4, 22), timezone: "Europe/Berlin")
  end
end
```

Create `test/models/weather_record_test.rb`:

```ruby
require "test_helper"

class WeatherRecordTest < ActiveSupport::TestCase
  setup { WeatherRecord.delete_all }

  test "requires supported kind and daytime" do
    record = WeatherRecord.new(
      kind: "current",
      timestamp: Time.utc(2026, 5, 4, 12),
      lat: 52.52,
      lon: 13.405,
      daytime: "day"
    )

    assert record.valid?
  end

  test "rejects unsupported kind" do
    record = WeatherRecord.new(
      kind: "live",
      timestamp: Time.utc(2026, 5, 4, 12),
      lat: 52.52,
      lon: 13.405,
      daytime: "day"
    )

    assert_not record.valid?
    assert_includes record.errors[:kind], "is not included in the list"
  end

  test "returns asset name" do
    record = WeatherRecord.new(icon: "cloudy", daytime: "night")

    assert_equal "weather_cloudy_night.webp", record.asset_name
  end
end
```

- [ ] **Step 2: Run tests and verify failure**

Run: `rtk bin/rails test test/test_weather_icon.rb test/models/weather_record_test.rb`

Expected: failures because `WeatherIcon`, `WeatherRecord`, and table do not exist.

- [ ] **Step 3: Add migration**

Create `db/migrate/20260504000000_create_weather_records.rb`:

```ruby
class CreateWeatherRecords < ActiveRecord::Migration[8.1]
  def change
    create_table :weather_records do |t|
      t.string :kind, null: false
      t.datetime :timestamp, null: false
      t.float :lat, null: false
      t.float :lon, null: false
      t.integer :source_id
      t.float :precipitation
      t.float :pressure_msl
      t.float :sunshine
      t.float :temperature
      t.integer :wind_direction
      t.float :wind_speed
      t.integer :cloud_cover
      t.float :dew_point
      t.integer :relative_humidity
      t.integer :visibility
      t.integer :wind_gust_direction
      t.float :wind_gust_speed
      t.string :condition
      t.integer :precipitation_probability
      t.integer :precipitation_probability_6h
      t.float :solar
      t.string :icon
      t.string :daytime, null: false
      t.timestamps
    end

    add_index :weather_records, [ :kind, :lat, :lon, :timestamp ], unique: true, name: "idx_weather_records_identity"
    add_index :weather_records, [ :lat, :lon, :timestamp ], name: "idx_weather_records_location_ts"
  end
end
```

- [ ] **Step 4: Add icon mapping**

Create `lib/weather_icon.rb`:

```ruby
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
```

- [ ] **Step 5: Add model**

Create `app/models/weather_record.rb`:

```ruby
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
```

- [ ] **Step 6: Migrate test database and run tests**

Run:

```bash
rtk bin/rails db:migrate
rtk bin/rails test test/test_weather_icon.rb test/models/weather_record_test.rb
```

Expected: tests pass and `db/schema.rb` includes `weather_records`.

- [ ] **Step 7: Commit**

```bash
rtk git add db/migrate/20260504000000_create_weather_records.rb db/schema.rb app/models/weather_record.rb lib/weather_icon.rb test/models/weather_record_test.rb test/test_weather_icon.rb
rtk git commit -m "Add weather record model"
```

## Task 3: Brightsky Client

**Files:**
- Create: `lib/brightsky_client.rb`
- Test: `test/test_brightsky_client.rb`

- [ ] **Step 1: Add failing client tests**

Create `test/test_brightsky_client.rb`:

```ruby
require "test_helper"
require "brightsky_client"

class BrightskyClientTest < Minitest::Test
  def setup
    @client = BrightskyClient.new(lat: 52.52, lon: 13.405, timezone: "Europe/Berlin")
  end

  def test_fetches_current_weather
    stub_request(:get, "https://api.brightsky.dev/current_weather")
      .with(query: { lat: "52.52", lon: "13.405" })
      .to_return(status: 200, body: {
        weather: {
          timestamp: "2026-05-04T15:00:00+00:00",
          source_id: 303711,
          temperature: 16.2,
          condition: "dry",
          icon: "cloudy",
          cloud_cover: 88,
          wind_speed_10: 13.7,
          precipitation_10: 0.0,
          solar_10: 0.072,
          relative_humidity: 47,
          pressure_msl: 1011.8
        }
      }.to_json, headers: { "Content-Type" => "application/json" })

    weather = @client.current_weather

    assert_equal Time.parse("2026-05-04T15:00:00+00:00"), weather.fetch(:timestamp)
    assert_equal 303711, weather.fetch(:source_id)
    assert_in_delta 16.2, weather.fetch(:temperature)
    assert_equal "cloudy", weather.fetch(:icon)
    assert_equal "day", weather.fetch(:daytime)
    assert_in_delta 13.7, weather.fetch(:wind_speed)
    assert_in_delta 0.0, weather.fetch(:precipitation)
    assert_in_delta 0.072, weather.fetch(:solar)
  end

  def test_fetches_hourly_weather_for_date
    stub_request(:get, "https://api.brightsky.dev/weather")
      .with(query: { lat: "52.52", lon: "13.405", date: "2026-05-04" })
      .to_return(status: 200, body: {
        weather: [
          {
            timestamp: "2026-05-04T00:00:00+02:00",
            source_id: 7003,
            precipitation: 0,
            pressure_msl: 1011.6,
            sunshine: nil,
            temperature: 16.2,
            wind_direction: 210,
            wind_speed: 9.7,
            cloud_cover: 100,
            dew_point: 12.7,
            relative_humidity: 80,
            visibility: 42600,
            wind_gust_direction: 220,
            wind_gust_speed: 18.7,
            condition: "dry",
            precipitation_probability: nil,
            precipitation_probability_6h: nil,
            solar: nil,
            icon: "cloudy"
          }
        ]
      }.to_json, headers: { "Content-Type" => "application/json" })

    rows = @client.weather_for_date(Date.new(2026, 5, 4))

    assert_equal 1, rows.length
    assert_equal 7003, rows.first.fetch(:source_id)
    assert_equal "cloudy", rows.first.fetch(:icon)
    assert_equal "night", rows.first.fetch(:daytime)
  end

  def test_weather_for_date_returns_range_end_for_404
    stub_request(:get, "https://api.brightsky.dev/weather")
      .with(query: { lat: "52.52", lon: "13.405", date: "2026-05-15" })
      .to_return(status: 404, body: "{}")

    assert_equal :range_end, @client.weather_for_date(Date.new(2026, 5, 15))
  end
end
```

- [ ] **Step 2: Run tests and verify failure**

Run: `rtk bin/rails test test/test_brightsky_client.rb`

Expected: failure because `BrightskyClient` is missing.

- [ ] **Step 3: Implement client**

Create `lib/brightsky_client.rb`:

```ruby
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
      daytime: WeatherIcon.daytime_for(icon: row["icon"], timestamp: timestamp, timezone: @timezone)
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
      daytime: WeatherIcon.daytime_for(icon: row["icon"], timestamp: timestamp, timezone: @timezone)
    }
  end
end
```

- [ ] **Step 4: Run tests and commit**

Run: `rtk bin/rails test test/test_brightsky_client.rb`

Expected: tests pass.

Commit:

```bash
rtk git add lib/brightsky_client.rb test/test_brightsky_client.rb
rtk git commit -m "Add Bright Sky client"
```

## Task 4: Weather Sync and Jobs

**Files:**
- Create: `lib/weather_sync.rb`
- Create: `app/jobs/weather_current_job.rb`
- Create: `app/jobs/weather_today_job.rb`
- Create: `app/jobs/weather_forecast_job.rb`
- Create: `app/jobs/weather_historic_job.rb`
- Modify: `config/recurring.yml`
- Test: `test/test_weather_sync.rb`
- Test: `test/jobs/weather_current_job_test.rb`
- Test: `test/jobs/weather_forecast_job_test.rb`
- Test: `test/jobs/weather_historic_job_test.rb`

- [ ] **Step 1: Add sync tests**

Create `test/test_weather_sync.rb`:

```ruby
require "test_helper"
require "weather_sync"

class WeatherSyncTest < ActiveSupport::TestCase
  setup do
    WeatherRecord.delete_all
    DailyTotal.delete_all
    @config = ConfigLoader::Config.new(timezone: "Europe/Berlin", weather: ConfigLoader::WeatherCfg.new(lat: 52.52, lon: 13.405))
    @client = Minitest::Mock.new
    @sync = WeatherSync.new(config: @config, client: @client)
  end

  def weather_row(timestamp:)
    {
      timestamp: Time.parse(timestamp),
      source_id: 7003,
      temperature: 16.2,
      icon: "cloudy",
      daytime: "day"
    }
  end

  test "sync_current_keeps_one_current_row" do
    @client.expect(:current_weather, weather_row(timestamp: "2026-05-04T10:00:00+00:00"))
    @sync.sync_current

    @client.expect(:current_weather, weather_row(timestamp: "2026-05-04T10:15:00+00:00"))
    @sync.sync_current

    assert_equal 1, WeatherRecord.where(kind: "current").count
    assert_equal Time.parse("2026-05-04T10:15:00+00:00"), WeatherRecord.current.first.timestamp
  end

  test "historic_replaces_matching_forecast" do
    WeatherRecord.create!(kind: "forecast", lat: 52.52, lon: 13.405, timestamp: Time.parse("2026-05-04T10:00:00+00:00"), daytime: "day", icon: "cloudy")

    @client.expect(:weather_for_date, [ weather_row(timestamp: "2026-05-04T10:00:00+00:00") ], [ Date.new(2026, 5, 4) ])
    @sync.sync_historic_date(Date.new(2026, 5, 4))

    assert_equal 0, WeatherRecord.where(kind: "forecast").count
    assert_equal 1, WeatherRecord.where(kind: "historic").count
  end

  test "forecast_stops_on_range_end" do
    @client.expect(:weather_for_date, [ weather_row(timestamp: "2026-05-05T10:00:00+00:00") ], [ Date.new(2026, 5, 5) ])
    @client.expect(:weather_for_date, :range_end, [ Date.new(2026, 5, 6) ])

    @sync.sync_forecast(today: Date.new(2026, 5, 4), max_days: 3)

    assert_equal 1, WeatherRecord.where(kind: "forecast").count
  end

  test "backfills_daily_total_dates_without_historic_weather" do
    DailyTotal.create!(plug_id: "bkw", date: "2026-05-01", energy_wh: 1000)
    @client.expect(:weather_for_date, [ weather_row(timestamp: "2026-05-01T10:00:00+00:00") ], [ Date.new(2026, 5, 1) ])

    @sync.backfill_historic_from_daily_totals

    assert_equal 1, WeatherRecord.where(kind: "historic").count
  end
end
```

- [ ] **Step 2: Run sync tests and verify failure**

Run: `rtk bin/rails test test/test_weather_sync.rb`

Expected: failure because `WeatherSync` is missing.

- [ ] **Step 3: Implement WeatherSync**

Create `lib/weather_sync.rb`:

```ruby
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
```

- [ ] **Step 4: Add job tests**

Create `test/jobs/weather_current_job_test.rb`:

```ruby
require "test_helper"

class WeatherCurrentJobTest < ActiveJob::TestCase
  test "runs sync when weather is configured" do
    sync = Minitest::Mock.new
    sync.expect(:sync_current, nil)
    WeatherSync.stub(:from_app_config, sync) { WeatherCurrentJob.perform_now }
    sync.verify
  end

  test "does nothing when weather is not configured" do
    WeatherSync.stub(:from_app_config, nil) { WeatherCurrentJob.perform_now }
  end
end
```

Create `test/jobs/weather_forecast_job_test.rb`:

```ruby
require "test_helper"

class WeatherForecastJobTest < ActiveJob::TestCase
  test "runs forecast sync" do
    sync = Minitest::Mock.new
    sync.expect(:sync_forecast, nil, today: Date.new(2026, 5, 4))
    WeatherSync.stub(:from_app_config, sync) { WeatherForecastJob.perform_now(today: Date.new(2026, 5, 4)) }
    sync.verify
  end
end
```

Create `test/jobs/weather_historic_job_test.rb`:

```ruby
require "test_helper"

class WeatherHistoricJobTest < ActiveJob::TestCase
  test "syncs yesterday and backfills daily totals" do
    sync = Minitest::Mock.new
    sync.expect(:sync_historic_date, nil, [ Date.new(2026, 5, 3) ])
    sync.expect(:backfill_historic_from_daily_totals, nil)
    WeatherSync.stub(:from_app_config, sync) { WeatherHistoricJob.perform_now(today: Date.new(2026, 5, 4)) }
    sync.verify
  end
end
```

- [ ] **Step 5: Add jobs**

Create `app/jobs/weather_current_job.rb`:

```ruby
class WeatherCurrentJob < ApplicationJob
  queue_as :default

  def perform
    sync = WeatherSync.from_app_config
    return Rails.logger.info("weather: not configured") if sync.nil?
    sync.sync_current
  end
end
```

Create `app/jobs/weather_today_job.rb`:

```ruby
class WeatherTodayJob < ApplicationJob
  queue_as :default

  def perform(today: Date.current)
    sync = WeatherSync.from_app_config
    return Rails.logger.info("weather: not configured") if sync.nil?
    sync.sync_today(today: today)
  end
end
```

Create `app/jobs/weather_forecast_job.rb`:

```ruby
class WeatherForecastJob < ApplicationJob
  queue_as :default

  def perform(today: Date.current)
    sync = WeatherSync.from_app_config
    return Rails.logger.info("weather: not configured") if sync.nil?
    sync.sync_forecast(today: today)
  end
end
```

Create `app/jobs/weather_historic_job.rb`:

```ruby
class WeatherHistoricJob < ApplicationJob
  queue_as :default

  def perform(today: Date.current)
    sync = WeatherSync.from_app_config
    return Rails.logger.info("weather: not configured") if sync.nil?
    sync.sync_historic_date(today - 1)
    sync.backfill_historic_from_daily_totals
  end
end
```

- [ ] **Step 6: Register recurring jobs**

Append the weather entries to the `aggregator_schedule` anchor in `config/recurring.yml`:

```yaml
  fetch_current_weather:
    class: WeatherCurrentJob
    queue: default
    schedule: every 15 minutes

  fetch_today_weather:
    class: WeatherTodayJob
    queue: default
    schedule: every hour

  fetch_weather_forecast:
    class: WeatherForecastJob
    queue: default
    schedule: every 3 hours

  fetch_historic_weather:
    class: WeatherHistoricJob
    queue: default
    schedule: at 3:45am every day
```

- [ ] **Step 7: Run tests and commit**

Run:

```bash
rtk bin/rails test test/test_weather_sync.rb test/jobs/weather_current_job_test.rb test/jobs/weather_forecast_job_test.rb test/jobs/weather_historic_job_test.rb
```

Expected: tests pass.

Commit:

```bash
rtk git add lib/weather_sync.rb app/jobs/weather_current_job.rb app/jobs/weather_today_job.rb app/jobs/weather_forecast_job.rb app/jobs/weather_historic_job.rb config/recurring.yml test/test_weather_sync.rb test/jobs/weather_current_job_test.rb test/jobs/weather_forecast_job_test.rb test/jobs/weather_historic_job_test.rb
rtk git commit -m "Add weather sync jobs"
```

## Task 5: Process Weather Icon Assets

**Files:**
- Read: `tmp/weather-icons/*.png`
- Create: `app/assets/images/weather_*.webp`

- [ ] **Step 1: Confirm source files exist**

Run: `rtk proxy find tmp/weather-icons -maxdepth 1 -type f`

Expected: 22 PNG files.

- [ ] **Step 2: Freistellen and export assets**

Use the image editing tool to remove the white background from each source PNG, keep the icon itself unchanged, and export transparent-background WebP files to `app/assets/images` with this exact mapping:

```text
tmp/weather-icons/ChatGPT Image 4. Mai 2026, 17_40_58 (1).png -> app/assets/images/weather_clear_day.webp
tmp/weather-icons/ChatGPT Image 4. Mai 2026, 17_40_58 (2).png -> app/assets/images/weather_clear_night.webp
tmp/weather-icons/ChatGPT Image 4. Mai 2026, 17_40_58 (3).png -> app/assets/images/weather_partly_cloudy_day.webp
tmp/weather-icons/ChatGPT Image 4. Mai 2026, 17_40_58 (4).png -> app/assets/images/weather_partly_cloudy_night.webp
tmp/weather-icons/ChatGPT Image 4. Mai 2026, 17_40_58 (5).png -> app/assets/images/weather_cloudy_day.webp
tmp/weather-icons/ChatGPT Image 4. Mai 2026, 17_40_58 (6).png -> app/assets/images/weather_cloudy_night.webp
tmp/weather-icons/ChatGPT Image 4. Mai 2026, 17_40_58 (7).png -> app/assets/images/weather_fog_day.webp
tmp/weather-icons/ChatGPT Image 4. Mai 2026, 17_40_58 (8).png -> app/assets/images/weather_fog_night.webp
tmp/weather-icons/ChatGPT Image 4. Mai 2026, 17_40_58 (9).png -> app/assets/images/weather_wind_day.webp
tmp/weather-icons/ChatGPT Image 4. Mai 2026, 17_40_58 (10).png -> app/assets/images/weather_wind_night.webp
tmp/weather-icons/ChatGPT Image 4. Mai 2026, 17_43_53 (1).png -> app/assets/images/weather_rain_day.webp
tmp/weather-icons/ChatGPT Image 4. Mai 2026, 17_43_53 (2).png -> app/assets/images/weather_rain_night.webp
tmp/weather-icons/ChatGPT Image 4. Mai 2026, 17_43_55 (3).png -> app/assets/images/weather_sleet_day.webp
tmp/weather-icons/ChatGPT Image 4. Mai 2026, 17_43_55 (4).png -> app/assets/images/weather_sleet_night.webp
tmp/weather-icons/ChatGPT Image 4. Mai 2026, 17_43_56 (5).png -> app/assets/images/weather_snow_day.webp
tmp/weather-icons/ChatGPT Image 4. Mai 2026, 17_43_56 (6).png -> app/assets/images/weather_snow_night.webp
tmp/weather-icons/ChatGPT Image 4. Mai 2026, 17_43_57 (7).png -> app/assets/images/weather_hail_day.webp
tmp/weather-icons/ChatGPT Image 4. Mai 2026, 17_43_57 (8).png -> app/assets/images/weather_hail_night.webp
tmp/weather-icons/ChatGPT Image 4. Mai 2026, 17_43_57 (9).png -> app/assets/images/weather_thunderstorm_day.webp
tmp/weather-icons/ChatGPT Image 4. Mai 2026, 17_43_57 (10).png -> app/assets/images/weather_thunderstorm_night.webp
tmp/weather-icons/ChatGPT Image 4. Mai 2026, 17_45_44 (1).png -> app/assets/images/weather_unknown_day.webp
tmp/weather-icons/ChatGPT Image 4. Mai 2026, 17_45_45 (2).png -> app/assets/images/weather_unknown_night.webp
```

- [ ] **Step 3: Verify assets**

Run: `rtk proxy find app/assets/images -maxdepth 1 -name 'weather_*.webp'`

Expected: 22 files.

Open at least one day icon and one night icon with the image viewer and verify the background is transparent or visually clean against the app background.

- [ ] **Step 4: Commit**

```bash
rtk git add app/assets/images/weather_*.webp
rtk git commit -m "Add weather icon assets"
```

## Task 6: Weather Page

**Files:**
- Create: `app/controllers/weather_controller.rb`
- Create: `app/views/weather/index.html.erb`
- Modify: `config/routes.rb`
- Modify: `app/views/layouts/application.html.erb`
- Modify: `app/assets/stylesheets/application.css`
- Test: `test/controllers/weather_controller_test.rb`
- Modify test: `test/controllers/reports_controller_test.rb`

- [ ] **Step 1: Add controller tests**

Create `test/controllers/weather_controller_test.rb`:

```ruby
require "test_helper"

class WeatherControllerTest < ActionDispatch::IntegrationTest
  setup { WeatherRecord.delete_all }

  test "renders empty state without weather data" do
    get "/weather"

    assert_response :success
    assert_select ".empty-state", text: /Noch keine Wetterdaten/
  end

  test "renders current weather today and next days" do
    WeatherRecord.create!(kind: "current", lat: 52.52, lon: 13.405, timestamp: Time.zone.parse("2026-05-04 12:00"), daytime: "day", icon: "cloudy", temperature: 16.2, condition: "dry", wind_speed: 9.7, relative_humidity: 80, cloud_cover: 100, precipitation: 0, pressure_msl: 1011.6)
    WeatherRecord.create!(kind: "forecast", lat: 52.52, lon: 13.405, timestamp: Time.zone.parse("2026-05-04 13:00"), daytime: "day", icon: "partly-cloudy-day", temperature: 18, precipitation: 0, solar: 320, wind_speed: 11)
    WeatherRecord.create!(kind: "forecast", lat: 52.52, lon: 13.405, timestamp: Time.zone.parse("2026-05-05 12:00"), daytime: "day", icon: "clear-day", temperature: 20, precipitation_probability: 4, solar: 480, wind_speed: 12)

    get "/weather"

    assert_response :success
    assert_select ".weather-current"
    assert_select ".weather-current", text: /16,2/
    assert_select ".weather-hour-card", minimum: 1
    assert_select ".weather-day-card", minimum: 1
    assert_select ".weather-solar", text: /320 W\/m²/
  end
end
```

Add this assertion to the navigation test in `test/controllers/reports_controller_test.rb`:

```ruby
assert_select "nav.app-nav a[href='#{weather_path}']", text: "Wetter"
```

- [ ] **Step 2: Run tests and verify failure**

Run: `rtk bin/rails test test/controllers/weather_controller_test.rb test/controllers/reports_controller_test.rb`

Expected: route/controller/navigation failures.

- [ ] **Step 3: Add route, controller, and navigation**

Add to `config/routes.rb`:

```ruby
get "/weather", to: "weather#index"
```

Create `app/controllers/weather_controller.rb`:

```ruby
class WeatherController < ApplicationController
  def index
    @current_weather = WeatherRecord.current.order(updated_at: :desc).first
    @today_weather = WeatherRecord.where(timestamp: Time.zone.today.all_day).where(kind: [ "forecast", "historic" ]).order(:timestamp)
    @future_weather = WeatherRecord.where(kind: "forecast").where("timestamp > ?", Time.zone.today.end_of_day).order(:timestamp).group_by { |record| record.timestamp.to_date }
  end
end
```

In `app/views/layouts/application.html.erb`, add:

```erb
<%= link_to "Wetter", weather_path, class: [ "app-nav-link", ("active" if current_page?(weather_path)) ] %>
```

- [ ] **Step 4: Add weather view**

Create `app/views/weather/index.html.erb`:

```erb
<% content_for :title, "Wetter" %>

<div class="weather-page">
  <% if @current_weather.nil? && @today_weather.empty? && @future_weather.empty? %>
    <section class="chart-card empty-state">
      <h2>Noch keine Wetterdaten</h2>
      <p>Die Wetteransicht erscheint, sobald Bright Sky Daten geladen hat.</p>
    </section>
  <% else %>
    <% if @current_weather %>
      <section class="weather-current chart-card">
        <%= image_tag @current_weather.asset_name, class: "weather-current-icon", alt: @current_weather.icon.to_s %>
        <div class="weather-current-main">
          <div class="tile-label">Jetzt</div>
          <div class="weather-current-temp"><%= number_with_precision(@current_weather.temperature, precision: 1, delimiter: ".", separator: ",") %> °C</div>
          <div class="muted-text"><%= @current_weather.condition || "Wetter" %> · Wind <%= number_with_precision(@current_weather.wind_speed || 0, precision: 0, delimiter: ".", separator: ",") %> km/h</div>
        </div>
        <div class="weather-current-facts">
          <div><strong><%= @current_weather.relative_humidity || "—" %>%</strong><br>Luft</div>
          <div><strong><%= @current_weather.cloud_cover || "—" %>%</strong><br>Wolken</div>
          <div><strong><%= number_with_precision(@current_weather.precipitation || 0, precision: 1, delimiter: ".", separator: ",") %> mm</strong><br>Regen</div>
          <div><strong><%= number_with_precision(@current_weather.pressure_msl || 0, precision: 0, delimiter: ".", separator: ",") %></strong><br>hPa</div>
        </div>
      </section>
    <% end %>

    <div class="section-label">Heute</div>
    <section class="weather-hour-row" aria-label="Heute">
      <% @today_weather.each do |record| %>
        <article class="weather-hour-card">
          <div class="weather-hour-top"><span><%= record.timestamp.strftime("%H:%M") %></span><span><%= number_with_precision(record.precipitation || record.precipitation_probability || 0, precision: 0, delimiter: ".", separator: ",") %><%= record.precipitation ? " mm" : "%" %></span></div>
          <%= image_tag record.asset_name, class: "weather-hour-icon", alt: record.icon.to_s %>
          <strong><%= number_with_precision(record.temperature, precision: 0, delimiter: ".", separator: ",") %>°</strong>
          <% if record.solar %>
            <div class="weather-solar">Sonne <%= number_with_precision(record.solar, precision: 0, delimiter: ".", separator: ",") %> W/m²</div>
          <% else %>
            <div>Wolken <%= record.cloud_cover || "—" %>%</div>
          <% end %>
          <div>Wind <%= number_with_precision(record.wind_speed || 0, precision: 0, delimiter: ".", separator: ",") %> km/h</div>
        </article>
      <% end %>
    </section>

    <div class="section-label">Nächste Tage</div>
    <section class="weather-days">
      <% @future_weather.each do |date, records| %>
        <article class="weather-day-card">
          <header><strong><%= l(date, format: "%A") rescue date.to_s %></strong></header>
          <div class="weather-day-slots">
            <% records.select { |r| (r.timestamp.hour % 3).zero? }.each do |record| %>
              <div class="weather-day-slot">
                <div><%= record.timestamp.strftime("%H") %></div>
                <%= image_tag record.asset_name, class: "weather-day-icon", alt: record.icon.to_s %>
                <strong><%= number_with_precision(record.temperature, precision: 0, delimiter: ".", separator: ",") %>°</strong>
                <div><%= record.precipitation ? number_with_precision(record.precipitation, precision: 1, delimiter: ".", separator: ",") + " mm" : "#{record.precipitation_probability || 0}%" %></div>
                <div><%= record.solar ? number_with_precision(record.solar, precision: 0, delimiter: ".", separator: ",") + " W/m²" : "Wolken #{record.cloud_cover || "—"}%" %></div>
              </div>
            <% end %>
          </div>
        </article>
      <% end %>
    </section>
  <% end %>
</div>
```

- [ ] **Step 5: Add styles**

Append to `app/assets/stylesheets/application.css`:

```css
.weather-current {
  display: flex;
  align-items: center;
  gap: 18px;
}
.weather-current-icon {
  width: 82px;
  height: 82px;
  object-fit: contain;
}
.weather-current-main {
  flex: 1;
  min-width: 0;
}
.weather-current-temp {
  font-size: 36px;
  font-weight: 700;
  line-height: 1;
}
.weather-current-facts {
  display: grid;
  grid-template-columns: repeat(2, minmax(64px, 1fr));
  gap: 10px;
  color: var(--muted);
  font-size: 12px;
}
.weather-hour-row {
  display: flex;
  gap: 10px;
  overflow-x: auto;
  padding-bottom: 6px;
  margin-bottom: 16px;
}
.weather-hour-card {
  min-width: 132px;
  background: var(--card);
  border: 1px solid var(--border);
  border-radius: 8px;
  padding: 12px;
  color: var(--muted);
  font-size: 12px;
}
.weather-hour-top {
  display: flex;
  justify-content: space-between;
}
.weather-hour-icon {
  width: 42px;
  height: 42px;
  object-fit: contain;
  display: block;
  margin: 8px 0;
}
.weather-hour-card strong {
  color: var(--text);
  font-size: 22px;
}
.weather-days {
  display: grid;
  grid-template-columns: repeat(2, minmax(0, 1fr));
  gap: 12px;
}
.weather-day-card {
  background: var(--card);
  border: 1px solid var(--border);
  border-radius: 10px;
  padding: 12px;
}
.weather-day-slots {
  display: grid;
  grid-template-columns: repeat(4, minmax(0, 1fr));
  gap: 8px;
}
.weather-day-slot {
  color: var(--muted);
  font-size: 11px;
  text-align: center;
}
.weather-day-icon {
  width: 34px;
  height: 34px;
  object-fit: contain;
}
@media (max-width: 640px) {
  .weather-current {
    align-items: flex-start;
    flex-wrap: wrap;
  }
  .weather-current-facts {
    width: 100%;
    grid-template-columns: repeat(4, minmax(0, 1fr));
  }
  .weather-days {
    grid-template-columns: 1fr;
  }
}
```

- [ ] **Step 6: Run tests and commit**

Run: `rtk bin/rails test test/controllers/weather_controller_test.rb test/controllers/reports_controller_test.rb`

Expected: tests pass.

Commit:

```bash
rtk git add app/controllers/weather_controller.rb app/views/weather/index.html.erb config/routes.rb app/views/layouts/application.html.erb app/assets/stylesheets/application.css test/controllers/weather_controller_test.rb test/controllers/reports_controller_test.rb
rtk git commit -m "Add weather page"
```

## Task 7: Dashboard Weather Icon Integration

**Files:**
- Modify: `app/controllers/dashboard_controller.rb`
- Modify: `app/views/dashboard/index.html.erb`
- Modify: `test/controllers/dashboard_controller_test.rb`

- [ ] **Step 1: Add dashboard tests**

Replace the PV icon assertion in `test/controllers/dashboard_controller_test.rb` with:

```ruby
test "uses current weather icon in hero and pv energy flow node" do
  WeatherRecord.delete_all
  WeatherRecord.create!(kind: "current", lat: 52.52, lon: 13.405, timestamp: Time.zone.parse("2026-05-04 12:00"), daytime: "night", icon: "cloudy")

  get "/"
  assert_response :ok

  assert_select "img.hero-icon[src*='weather_cloudy_night']", 1
  assert_select "image[href*='weather_cloudy_night'][x='184'][y='55'][width='32'][height='32']", 1
end

test "falls back to sun icon without current weather" do
  WeatherRecord.delete_all

  get "/"
  assert_response :ok

  assert_select "img.hero-icon[src*='icon_sonne']", 1
  assert_select "image[href*='icon_sonne'][x='184'][y='55'][width='32'][height='32']", 1
end
```

- [ ] **Step 2: Run tests and verify failure**

Run: `rtk bin/rails test test/controllers/dashboard_controller_test.rb`

Expected: first test fails because Dashboard still uses `icon_sonne.webp`.

- [ ] **Step 3: Expose dashboard weather asset**

Modify `app/controllers/dashboard_controller.rb`:

```ruby
class DashboardController < ApplicationController
  def index
    current_weather = WeatherRecord.current.order(updated_at: :desc).first
    @dashboard_weather_asset = current_weather&.asset_name || "icon_sonne.webp"
    @dashboard_weather_alt = current_weather&.icon.presence || "Sonne"
  end
end
```

- [ ] **Step 4: Replace dashboard icon references**

In `app/views/dashboard/index.html.erb`, replace the hero image with:

```erb
<%= image_tag @dashboard_weather_asset, class: "hero-icon", alt: @dashboard_weather_alt %>
```

Replace the PV SVG image with:

```erb
<image href="<%= asset_path @dashboard_weather_asset %>" x="184" y="55" width="32" height="32"/>
```

- [ ] **Step 5: Run tests and commit**

Run: `rtk bin/rails test test/controllers/dashboard_controller_test.rb`

Expected: tests pass.

Commit:

```bash
rtk git add app/controllers/dashboard_controller.rb app/views/dashboard/index.html.erb test/controllers/dashboard_controller_test.rb
rtk git commit -m "Show weather icon on dashboard"
```

## Task 8: Full Verification

**Files:**
- No planned edits unless verification reveals a defect.

- [ ] **Step 1: Run targeted weather tests**

Run:

```bash
rtk bin/rails test test/test_config_loader.rb test/test_weather_icon.rb test/models/weather_record_test.rb test/test_brightsky_client.rb test/test_weather_sync.rb test/jobs/weather_current_job_test.rb test/jobs/weather_forecast_job_test.rb test/jobs/weather_historic_job_test.rb test/controllers/weather_controller_test.rb test/controllers/dashboard_controller_test.rb
```

Expected: all tests pass.

- [ ] **Step 2: Run full test suite**

Run: `rtk bin/rails test`

Expected: all tests pass.

- [ ] **Step 3: Run app checks**

Run:

```bash
rtk bin/rails routes | grep weather
rtk bin/rails runner 'puts WeatherIcon.asset_name("cloudy", "night")'
```

Expected:

```text
/weather route is listed
weather_cloudy_night.webp
```

- [ ] **Step 4: Start local server for manual review**

Run: `rtk bin/rails server -p 3000`

Open:

- `http://localhost:3000/`
- `http://localhost:3000/weather`

Expected:

- Dashboard renders.
- Weather navigation appears.
- Weather page renders either an empty state or weather records.
- Dashboard uses the current weather icon when a current weather record exists.

- [ ] **Step 5: Commit any verification fixes**

If a verification defect required edits, commit only those edits:

```bash
rtk git add <changed-files>
rtk git commit -m "Fix weather verification issues"
```

If no edits were required, do not create an empty commit.

## Self-Review

- Spec coverage: configuration, data model, Bright Sky client, jobs, recurring schedule, weather page, dashboard icon replacement, icon source mapping, freistellen/WebP assets, error handling, and tests are covered.
- Placeholder scan: no `TBD`, `TODO`, `FIXME`, or unspecified implementation steps remain.
- Type consistency: plan uses `WeatherRecord`, `WeatherIcon`, `BrightskyClient`, and `WeatherSync` consistently across tasks.
