class ApiController < ApplicationController
  def today
    end_ts   = Time.now.to_i
    start_ts = ((end_ts - 86_400) / 3600) * 3600

    grouped = Sample.where(ts: start_ts..(end_ts - 1))
                    .group(:plug_id, Arel.sql("(ts / 60) * 60"))
                    .select("plug_id, (ts / 60) * 60 AS minute_ts, AVG(apower_w) AS avg_power_w")

    @series = app_config.plugs.map do |plug|
      points = grouped
        .select { |r| r.plug_id == plug.id }
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

    rows = DailyTotal.where("date >= ?", cutoff).order(:date)

    @series = app_config.plugs.map do |plug|
      points = rows.select { |r| r.plug_id == plug.id }
                   .map { |r| { date: r.date, energy_wh: r.energy_wh } }
      { plug_id: plug.id, name: plug.name, role: plug.role, points: points }
    end
  end

  def live
    threshold = app_config.poll.interval_seconds * 2
    @now_ts   = Time.now.to_i
    plug_ids  = app_config.plugs.map(&:id)

    max_ts_by_plug = Sample.where(plug_id: plug_ids).group(:plug_id).maximum(:ts)

    @plugs = app_config.plugs.map do |plug|
      max_ts = max_ts_by_plug[plug.id]
      latest = max_ts ? Sample.find_by(plug_id: plug.id, ts: max_ts) : nil
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
  end

  private

  def app_config
    Rails.application.ziwoas_app.config
  end
end
