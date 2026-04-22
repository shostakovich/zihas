require "sinatra/base"
require "json"
require "gruff"
require "config_loader"
require "db"
require "tzinfo"
require "savings_calculator"
require "date"
require "time"

class Web < Sinatra::Base
  configure do
    set :views,  File.expand_path("views", __dir__)
    set :public_folder, File.expand_path("../public", __dir__)

    config_path   = ENV.fetch("CONFIG_PATH")
    database_path = ENV.fetch("DATABASE_PATH")

    config = ConfigLoader.load(config_path)
    db     = DB.connect(database_path)
    DB.migrate!(db)

    set :config, config
    set :db, db
    set :stale_threshold_seconds, config.poll.interval_seconds * 2
  end

  helpers do
    def local_tz
      @local_tz ||= TZInfo::Timezone.get(settings.config.timezone)
    end

    def today_bounds_utc
      now_utc     = Time.now.utc
      local_today = local_tz.utc_to_local(now_utc).to_date
      midnight    = Time.new(local_today.year, local_today.month, local_today.day, 0, 0, 0)
      start_utc   = local_tz.local_to_utc(midnight).to_i
      [start_utc, start_utc + 86_400, local_today]
    end

    def producer_ids
      settings.config.plugs.select { |p| p.role == :producer }.map(&:id)
    end

    def consumer_ids
      settings.config.plugs.select { |p| p.role == :consumer }.map(&:id)
    end

    def energy_delta_wh(plug_ids, start_ts, end_ts)
      return 0.0 if plug_ids.empty?
      rows = settings.db[:samples]
        .where(plug_id: plug_ids, ts: start_ts..(end_ts - 1))
        .select_group(:plug_id)
        .select_append(
          (Sequel.function(:max, :aenergy_wh) - Sequel.function(:min, :aenergy_wh)).as(:delta)
        )
        .all
      rows.sum { |r| r[:delta] || 0 }.to_f
    end

    def fmt_de(num, digits = 2)
      ("%.#{digits}f" % num).gsub(".", ",")
    end

    def live_data
      threshold = settings.stale_threshold_seconds
      now       = Time.now.to_i
      plugs = settings.config.plugs.map do |plug|
        latest = settings.db[:samples].where(plug_id: plug.id).order(Sequel.desc(:ts)).first
        online = !latest.nil? && (now - latest[:ts]) <= threshold
        {
          id:       plug.id,
          name:     plug.name,
          role:     plug.role,
          online:   online,
          apower_w: online ? latest[:apower_w] : nil,
        }
      end
      { plugs: plugs }
    end

    def summary_data
      start_ts, end_ts, _today = today_bounds_utc
      calc      = SavingsCalculator.new(price_eur_per_kwh: settings.config.electricity_price_eur_per_kwh)
      produced  = energy_delta_wh(producer_ids, start_ts, end_ts)
      consumed  = energy_delta_wh(consumer_ids, start_ts, end_ts)
      savings   = calc.savings_eur(produced)
      consumers = live_data[:plugs].select { |p| p[:role] == :consumer }
      consumption_w = consumers.select { |p| p[:online] }.sum { |p| p[:apower_w] || 0 }
      {
        produced_wh:   produced,
        consumed_wh:   consumed,
        savings_eur:   savings,
        consumption_w: consumption_w,
      }
    end

    def gruff_theme
      {
        colors:             %w[#f59f00 #228be6 #40c057 #fa5252],
        marker_color:       "#dee2e6",
        font_color:         "#6c757d",
        background_colors:  %w[#ffffff #ffffff],
      }
    end
  end

  # ── Pages ──────────────────────────────────────────────────────────────────

  get "/" do
    @live    = live_data
    @summary = summary_data
    erb :dashboard
  end

  # ── SSR fragments ──────────────────────────────────────────────────────────

  get "/fragments/live" do
    @live = live_data
    erb :live, layout: false
  end

  get "/fragments/summary" do
    @summary = summary_data
    erb :summary, layout: false
  end

  # ── Chart images ───────────────────────────────────────────────────────────

  get "/charts/today.png" do
    start_ts, _end_ts, _today = today_bounds_utc
    now_ts = Time.now.to_i

    grouped = settings.db[:samples]
      .where(ts: start_ts..(now_ts - 1))
      .select_group(:plug_id, Sequel.lit("(ts / 60) * 60").as(:minute_ts))
      .select_append(Sequel.function(:avg, :apower_w).as(:avg_power_w))
      .all

    n = [((now_ts - start_ts) / 60) + 1, 2].max

    g = Gruff::Line.new(680)
    g.title      = "Heute — Leistung über Zeit"
    g.hide_dots  = true
    g.minimum_value = 0
    g.theme      = gruff_theme

    labels = {}
    (0...n).step(120) { |i| labels[i] = Time.at(start_ts + i * 60).strftime("%H:%M") }
    g.labels = labels

    settings.config.plugs.each do |plug|
      values = Array.new(n, 0.0)
      grouped.select { |r| r[:plug_id] == plug.id }.each do |r|
        idx = ((r[:minute_ts] - start_ts) / 60).to_i
        values[idx] = r[:avg_power_w].to_f if idx >= 0 && idx < n
      end
      color = plug.role == :producer ? "#f59f00" : "#228be6"
      g.data(plug.name, values, color)
    end

    content_type "image/png"
    cache_control :no_store
    g.to_blob
  end

  get "/charts/history.png" do
    days      = 14
    all_dates = (1..days).map { |i| (Date.today - days + i).to_s }
    cutoff    = all_dates.first

    rows = settings.db[:daily_totals]
      .where(plug_id: producer_ids)
      .where { date >= cutoff }
      .all

    by_date = rows.group_by { |r| r[:date] }
                  .transform_values { |rs| rs.sum { |r| r[:energy_wh] } / 1000.0 }

    values = all_dates.map { |d| by_date[d] || 0.0 }
    labels = all_dates.each_with_index.map { |d, i|
      [i, Date.parse(d).strftime("%d.%m")]
    }.to_h

    g = Gruff::Bar.new(680)
    g.title         = "Letzte 14 Tage — Tages-Ertrag"
    g.minimum_value = 0
    g.theme         = gruff_theme
    g.labels        = labels
    g.data("kWh/Tag", values, "#f59f00")

    content_type "image/png"
    cache_control :no_store
    g.to_blob
  end

  # ── JSON APIs (kept for debugging / external use) ──────────────────────────

  get "/api/live" do
    content_type :json
    live_data.to_json
  end

  get "/api/today/summary" do
    start_ts, end_ts, today = today_bounds_utc
    calc = SavingsCalculator.new(price_eur_per_kwh: settings.config.electricity_price_eur_per_kwh)
    content_type :json
    {
      date:               today.to_s,
      produced_wh_today:  energy_delta_wh(producer_ids, start_ts, end_ts),
      consumed_wh_today:  energy_delta_wh(consumer_ids, start_ts, end_ts),
      savings_eur_today:  calc.savings_eur(energy_delta_wh(producer_ids, start_ts, end_ts)),
    }.to_json
  end

  get "/api/today" do
    start_ts, end_ts, _today = today_bounds_utc

    grouped = settings.db[:samples]
      .where(ts: start_ts..(end_ts - 1))
      .select_group(:plug_id, Sequel.lit("(ts / 60) * 60").as(:minute_ts))
      .select_append(Sequel.function(:avg, :apower_w).as(:avg_power_w))
      .all

    series = settings.config.plugs.map do |plug|
      points = grouped
        .select { |r| r[:plug_id] == plug.id }
        .map { |r| { ts: r[:minute_ts], avg_power_w: r[:avg_power_w].to_f } }
        .sort_by { |p| p[:ts] }
      { plug_id: plug.id, name: plug.name, role: plug.role, points: points }
    end

    content_type :json
    { series: series }.to_json
  end

  get "/api/history" do
    days   = (params["days"] || "14").to_i.clamp(1, 365)
    cutoff = (Date.today - days).to_s

    rows = settings.db[:daily_totals]
      .where { date >= cutoff }
      .order(:date)
      .all

    series = settings.config.plugs.map do |plug|
      points = rows.select { |r| r[:plug_id] == plug.id }
                   .map { |r| { date: r[:date], energy_wh: r[:energy_wh] } }
      { plug_id: plug.id, name: plug.name, role: plug.role, points: points }
    end

    content_type :json
    { days: days, series: series }.to_json
  end
end
