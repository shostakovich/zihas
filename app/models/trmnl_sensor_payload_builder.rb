class TrmnlSensorPayloadBuilder
  BUCKET_SECONDS = 15 * 60
  BUCKETS        = 12 # 3 hours of 15-min buckets

  def initialize(config:, now: Time.current)
    @config = config
    @now    = now
    @tz     = TZInfo::Timezone.get(config.timezone)
  end

  def build
    sensor_entries = @config.sensors.map { |s| build_sensor_entry(s) }
    stand          = compute_stand(sensor_entries)

    {
      "merge_variables" => {
        "stand"   => stand,
        "sensors" => sensor_entries
      }
    }
  end

  private

  def build_sensor_entry(sensor)
    type      = (sensor.type == :outdoor_meter) ? "outdoor" : "indoor"
    latest    = SensorReading.where(device_id: sensor.id).order(taken_at: :desc).first
    presenter = Sensors::ReadingPresenter.new(latest, now: @now)
    offline   = presenter.offline?

    entry = {
      "id"           => sensor.id,
      "name"         => sensor.name,
      "type"         => type,
      "primary"      => nil,
      "unit"         => (type == "outdoor") ? "°C" : "ppm CO₂",
      "ampel"        => nil,
      "trend"        => [],
      "trend_min"    => nil,
      "trend_max"    => nil,
      "temperature"  => nil,
      "humidity"     => nil,
      "battery_low"  => presenter.battery_low?,
      "battery_pct"  => latest&.battery_pct,
      "age_label"    => presenter.age_label,
      "offline"      => offline
    }

    return entry if offline

    if type == "outdoor"
      entry["primary"]     = latest.temperature.to_f.round(1)
      entry["temperature"] = entry["primary"]
      entry["humidity"]    = latest.humidity
    else
      entry["primary"]     = latest.co2.to_i
      entry["ampel"]       = presenter.co2_level&.to_s
      entry["temperature"] = latest.temperature.to_f.round(1)
      entry["humidity"]    = latest.humidity
    end

    trend = build_trend(sensor)
    entry["trend"] = trend
    non_null = trend.compact
    entry["trend_min"] = non_null.min
    entry["trend_max"] = non_null.max
    entry
  end

  def build_trend(sensor)
    start_ts, end_ts = window_bounds
    column = (sensor.type == :outdoor_meter) ? :temperature : :co2

    rows = SensorReading
             .where(device_id: sensor.id)
             .where("taken_at >= ? AND taken_at < ?", Time.at(start_ts), Time.at(end_ts))
             .pluck(:taken_at, column)

    buckets = Array.new(BUCKETS) { [] }
    rows.each do |taken_at, value|
      next if value.nil?
      idx = ((taken_at.to_i - start_ts) / BUCKET_SECONDS).to_i
      next if idx < 0 || idx >= BUCKETS
      buckets[idx] << value
    end

    buckets.map do |vals|
      next nil if vals.empty?
      avg = vals.sum.to_f / vals.length
      (column == :temperature) ? avg.round(1) : avg.round
    end
  end

  def window_bounds
    local_now = @tz.utc_to_local(@now.utc)
    quarter   = (local_now.min / 15) * 15
    slot_local = Time.new(local_now.year, local_now.month, local_now.day,
                          local_now.hour, quarter, 0)
    end_ts   = @tz.local_to_utc(slot_local).to_i + BUCKET_SECONDS
    start_ts = end_ts - BUCKETS * BUCKET_SECONDS
    [ start_ts, end_ts ]
  end

  def compute_stand(entries)
    latest_taken_ats = entries.filter_map { |e| sensor_taken_at(e["id"]) }
    latest = latest_taken_ats.max
    return @tz.utc_to_local(@now.utc).strftime("%H:%M") if latest.nil?
    @tz.utc_to_local(latest.utc).strftime("%H:%M")
  end

  def sensor_taken_at(device_id)
    SensorReading.where(device_id: device_id).maximum(:taken_at)
  end
end
