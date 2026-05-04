# Weather Area Design

## Goal

Ziwoas gets a new weather area next to Dashboard and Berichte. The app reads
weather data from Bright Sky for a configured location, shows current weather,
today's hourly weather, and a forecast for the next days. It also backfills and
stores historic weather for all days that already have energy totals.

The first version does not add weather-energy correlations to reports. Reports
stay unchanged.

## Configuration

`config/ziwoas.yml` gains a weather section:

```yaml
weather:
  lat: 52.52
  lon: 13.405
```

`ConfigLoader` adds `WeatherCfg` and validates:

- `weather` is optional.
- If present, `lat` and `lon` are required numeric values.
- Latitude must be between `-90` and `90`.
- Longitude must be between `-180` and `180`.

If weather is not configured, weather jobs log that weather is disabled and do
nothing. The weather page renders a clear empty state.

## Data Model

Add one structured table, `weather_records`, for current, forecast, and historic
weather.

Columns:

- Location and identity: `lat`, `lon`, `timestamp`, `kind`, `source_id`
- Bright-Sky fields:
  `precipitation`, `pressure_msl`, `sunshine`, `temperature`,
  `wind_direction`, `wind_speed`, `cloud_cover`, `dew_point`,
  `relative_humidity`, `visibility`, `wind_gust_direction`,
  `wind_gust_speed`, `condition`, `precipitation_probability`,
  `precipitation_probability_6h`, `solar`, `icon`
- Derived UI field: `daytime` with `day` or `night`
- Rails timestamps: `created_at`, `updated_at`

`kind` is one of:

- `current`: current weather from Bright Sky `/current_weather`
- `forecast`: future or not-yet-final hourly values from `/weather`
- `historic`: final past hourly weather from `/weather`

Upsert rules:

- `current`: keep exactly one current row per configured location. Each
  15-minute fetch replaces the previous current row.
- `forecast`: upsert by location and `timestamp`.
- `historic`: upsert by location and `timestamp`, and replace any forecast row
  for that same timestamp. Forecasts are not archived for later comparison.

For historic backfill, use `daily_totals` as the source of energy days. For every
date in `daily_totals` without complete historic weather, fetch and persist that
day.

## Bright Sky Client

Create `BrightskyClient` to encapsulate HTTP calls and response parsing.

Endpoints:

- `/current_weather?lat=...&lon=...`
- `/weather?lat=...&lon=...&date=YYYY-MM-DD`

The client returns normalized weather hashes that match `weather_records`
columns. It does not write to the database.

Forecast range behavior:

- The app requests future days until Bright Sky returns `404` or an empty
  weather response.
- Use a hard maximum of 10 future days to avoid unbounded loops.
- A test request on May 4, 2026 against Berlin coordinates returned data through
  May 14, 2026 and `404` for May 15, 2026, so the implementation should discover
  the current API range dynamically instead of assuming a fixed duration.

Error behavior:

- Timeouts, 5xx responses, and invalid JSON are logged and treated as a failed
  fetch for that run.
- Forecast `404` is not an error; it means the forecast range ended.
- The last stored weather remains visible when a fetch fails.

## Jobs

Use Solid Queue recurring jobs.

`WeatherCurrentJob`

- Schedule: every 15 minutes.
- Fetches `/current_weather`.
- Stores exactly one `current` record for the configured location.

`WeatherTodayJob`

- Schedule: every hour.
- Fetches `/weather` for today.
- Stores hourly rows used for today's preview.

`WeatherForecastJob`

- Schedule: every 3 hours.
- Fetches `/weather` for future days.
- Stores rows as `forecast`.
- Stops when Bright Sky returns `404`, an empty response, or the 10-day maximum
  is reached.

`WeatherHistoricJob`

- Schedule: daily after the existing energy aggregation, for example at 3:45am.
- Fetches yesterday as `historic`.
- Backfills `historic` rows for all dates in `daily_totals` that do not already
  have complete historic weather.
- Replaces matching forecast rows.

`config/recurring.yml` will add:

```yaml
fetch_current_weather:
  class: WeatherCurrentJob
  schedule: every 15 minutes

fetch_today_weather:
  class: WeatherTodayJob
  schedule: every hour

fetch_weather_forecast:
  class: WeatherForecastJob
  schedule: every 3 hours

fetch_historic_weather:
  class: WeatherHistoricJob
  schedule: at 3:45am every day
```

## Weather Page

Add route `/weather`, `WeatherController#index`, and a navigation entry
`Wetter`.

The first page layout is compact but visual:

1. Current weather card
   - large weather icon
   - temperature
   - condition text
   - wind, humidity, precipitation, cloud cover, pressure

2. Today
   - all available hourly rows for today
   - displayed as a horizontally scrollable time row or responsive multi-row
     grid
   - each card shows time, icon, temperature, precipitation, solar/clouds, wind
   - solar values are displayed with explicit units, for example
     `Sonne 320 W/m²`
   - if `solar` is missing, show cloud cover instead, for example
     `Wolken 95%`

3. Next days
   - grouped by date
   - 3-hour slots per day
   - each slot shows time, icon, temperature, precipitation, and solar/clouds

The Visual Companion direction approved for implementation is the refined
variant with a compact current card, larger hourly cards for today, and grouped
day cards for the next days.

## Dashboard Integration

The fixed `icon_sonne.webp` is replaced by the current weather icon in two
places:

- the Dashboard hero next to current PV power
- the PV node in the energy flow diagram

The label remains `PV-Anlage`; the icon only reflects the current weather. If no
current weather exists or a matching asset is missing, the Dashboard falls back
to the existing `icon_sonne.webp`.

## Weather Icons

The app maps Bright-Sky `icon` plus derived `daytime` to app assets. Generate
and store freestanding transparent-background WebP assets in
`app/assets/images`.

Final asset names:

```text
weather_clear_day.webp
weather_clear_night.webp
weather_partly_cloudy_day.webp
weather_partly_cloudy_night.webp
weather_cloudy_day.webp
weather_cloudy_night.webp
weather_fog_day.webp
weather_fog_night.webp
weather_wind_day.webp
weather_wind_night.webp
weather_rain_day.webp
weather_rain_night.webp
weather_sleet_day.webp
weather_sleet_night.webp
weather_snow_day.webp
weather_snow_night.webp
weather_hail_day.webp
weather_hail_night.webp
weather_thunderstorm_day.webp
weather_thunderstorm_night.webp
weather_unknown_day.webp
weather_unknown_night.webp
```

Source files in `tmp/weather-icons`:

| Final asset | Source file |
|---|---|
| `weather_clear_day.webp` | `ChatGPT Image 4. Mai 2026, 17_40_58 (1).png` |
| `weather_clear_night.webp` | `ChatGPT Image 4. Mai 2026, 17_40_58 (2).png` |
| `weather_partly_cloudy_day.webp` | `ChatGPT Image 4. Mai 2026, 17_40_58 (3).png` |
| `weather_partly_cloudy_night.webp` | `ChatGPT Image 4. Mai 2026, 17_40_58 (4).png` |
| `weather_cloudy_day.webp` | `ChatGPT Image 4. Mai 2026, 17_40_58 (5).png` |
| `weather_cloudy_night.webp` | `ChatGPT Image 4. Mai 2026, 17_40_58 (6).png` |
| `weather_fog_day.webp` | `ChatGPT Image 4. Mai 2026, 17_40_58 (7).png` |
| `weather_fog_night.webp` | `ChatGPT Image 4. Mai 2026, 17_40_58 (8).png` |
| `weather_wind_day.webp` | `ChatGPT Image 4. Mai 2026, 17_40_58 (9).png` |
| `weather_wind_night.webp` | `ChatGPT Image 4. Mai 2026, 17_40_58 (10).png` |
| `weather_rain_day.webp` | `ChatGPT Image 4. Mai 2026, 17_43_53 (1).png` |
| `weather_rain_night.webp` | `ChatGPT Image 4. Mai 2026, 17_43_53 (2).png` |
| `weather_sleet_day.webp` | `ChatGPT Image 4. Mai 2026, 17_43_55 (3).png` |
| `weather_sleet_night.webp` | `ChatGPT Image 4. Mai 2026, 17_43_55 (4).png` |
| `weather_snow_day.webp` | `ChatGPT Image 4. Mai 2026, 17_43_56 (5).png` |
| `weather_snow_night.webp` | `ChatGPT Image 4. Mai 2026, 17_43_56 (6).png` |
| `weather_hail_day.webp` | `ChatGPT Image 4. Mai 2026, 17_43_57 (7).png` |
| `weather_hail_night.webp` | `ChatGPT Image 4. Mai 2026, 17_43_57 (8).png` |
| `weather_thunderstorm_day.webp` | `ChatGPT Image 4. Mai 2026, 17_43_57 (9).png` |
| `weather_thunderstorm_night.webp` | `ChatGPT Image 4. Mai 2026, 17_43_57 (10).png` |
| `weather_unknown_day.webp` | `ChatGPT Image 4. Mai 2026, 17_45_44 (1).png` |
| `weather_unknown_night.webp` | `ChatGPT Image 4. Mai 2026, 17_45_45 (2).png` |

The implementation must remove the generated white backgrounds before using the
icons in the app, then convert them to WebP with the final names above. The
assets should remain visually consistent at both Dashboard hero size and small
forecast-card size.

Bright-Sky mapping:

- `clear-day` -> `weather_clear_day.webp`
- `clear-night` -> `weather_clear_night.webp`
- `partly-cloudy-day` -> `weather_partly_cloudy_day.webp`
- `partly-cloudy-night` -> `weather_partly_cloudy_night.webp`
- neutral icons (`cloudy`, `fog`, `wind`, `rain`, `sleet`, `snow`, `hail`,
  `thunderstorm`) use derived `daytime`
- unknown or missing icon uses `weather_unknown_day.webp` or
  `weather_unknown_night.webp`

`daytime` is derived from the Bright-Sky icon suffix when present. For neutral
icons, derive it from the timestamp and configured location. A simple first
implementation may derive day/night by local hour; if a sunrise/sunset helper is
added later, only this derivation needs to change.

## Tests

Config tests:

- `ConfigLoader` accepts optional `weather`.
- `ConfigLoader` requires valid numeric `lat` and `lon` when `weather` is
  present.

Client tests:

- `BrightskyClient` builds the expected `/current_weather` and `/weather`
  requests.
- It parses supported fields.
- It treats forecast `404` as range end.
- It handles timeout/5xx/invalid JSON without corrupting stored data.

Model/service tests:

- `WeatherRecord` or a mapper normalizes Bright-Sky rows to database fields.
- `daytime` and icon asset mapping produce expected filenames.
- Unknown icons fall back to unknown day/night assets.

Job tests:

- `WeatherCurrentJob` keeps exactly one current row.
- `WeatherTodayJob` stores today's hourly rows.
- `WeatherForecastJob` fetches future days, stops on `404`, and respects the
  10-day limit.
- `WeatherHistoricJob` writes historic rows, replaces matching forecast rows,
  and backfills dates from `daily_totals`.

Controller/view tests:

- `/weather` renders the not-configured empty state.
- `/weather` renders current weather, today's full hourly row, and grouped future
  days.
- Dashboard renders the current weather asset when available.
- Dashboard falls back to `icon_sonne.webp` when weather data or assets are
  missing.
