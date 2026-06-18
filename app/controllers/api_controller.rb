class ApiController < ApplicationController
  def today
    end_ts   = Time.now.to_i
    start_ts = ((end_ts - 86_400) / 3600) * 3600

    rows_by_plug = Sample.where(ts: start_ts..(end_ts - 1))
                         .group(:plug_id, Arel.sql("(ts / 60) * 60"))
                         .select("plug_id, (ts / 60) * 60 AS minute_ts, AVG(apower_w) AS avg_power_w")
                         .group_by(&:plug_id)

    @series = app_config.plugs.map do |plug|
      points = (rows_by_plug[plug.id] || [])
        .map { |r| { ts: r.minute_ts, avg_power_w: r.avg_power_w.to_f } }
        .sort_by { |p| p[:ts] }
      { plug_id: plug.id, name: plug.name, role: plug.role, points: points }
    end
  end

  def today_summary
    @summary = EnergySummary.new(config: app_config).compute_today
  end

  def history
    @days   = (params["days"] || "14").to_i.clamp(1, 365)
    cutoff = (Date.today - @days).to_s

    rows_by_plug = DailyTotal.where("date >= ?", cutoff).order(:date).group_by(&:plug_id)

    @series = app_config.plugs.map do |plug|
      points = (rows_by_plug[plug.id] || [])
                   .map { |r| { date: r.date, energy_wh: r.energy_wh } }
      { plug_id: plug.id, name: plug.name, role: plug.role, points: points }
    end
  end

  def live
    threshold = 120
    @now_ts   = Time.now.to_i
    config    = app_config
    plug_ids  = config.plugs.map(&:id)

    latest_by_plug = Sample
      .where(plug_id: plug_ids)
      .where("(plug_id, ts) IN (SELECT plug_id, MAX(ts) FROM samples WHERE plug_id IN (?) GROUP BY plug_id)", plug_ids)
      .index_by(&:plug_id)

    @plugs = config.plugs.map do |plug|
      latest = latest_by_plug[plug.id]
      online = latest.present? && (@now_ts - latest.ts) <= threshold
      {
        id:           plug.id,
        name:         plug.name,
        role:         plug.role,
        online:       online,
        apower_w:     online ? latest.apower_w : nil,
        last_seen_ts: latest&.ts
      }
    end

    consumer_w = @plugs
      .select { |p| p[:role] == :consumer && p[:online] }
      .sum { |p| p[:apower_w].to_f }

    solakon_cfg = config.solakon
    stale_after_s = solakon_cfg&.stale_after_s || threshold
    reading = if solakon_cfg&.monitoring_enabled
      SolakonReading.latest_fresh(stale_after_s: stale_after_s, now: Time.zone.at(@now_ts))
    end

    @energy_flow =
      if reading
        {
          solakon_online: true,
          home_w: consumer_w,
          solakon_ac_w: reading.active_power_w,
          solar_w: reading.pv_power_w,
          battery_soc_pct: reading.battery_soc_pct,
          battery_w: reading.battery_display_power_w,
          grid_w: consumer_w - reading.active_power_w
        }
      else
        {
          solakon_online: false,
          home_w: consumer_w,
          solakon_ac_w: nil,
          solar_w: nil,
          battery_soc_pct: nil,
          battery_w: nil,
          grid_w: nil
        }
      end
  end
end
