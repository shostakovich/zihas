require "sinatra/base"
require "json"
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
    def json_response(data)
      content_type :json
      data.to_json
    end

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
  end

  get "/" do
    erb :dashboard
  end

  get "/api/today" do
    end_ts   = Time.now.to_i
    start_ts = end_ts - 86_400

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

    json_response(series: series)
  end

  get "/api/today/summary" do
    start_ts, end_ts, today = today_bounds_utc
    calc = SavingsCalculator.new(price_eur_per_kwh: settings.config.electricity_price_eur_per_kwh)

    produced = energy_delta_wh(producer_ids, start_ts, end_ts)
    consumed = energy_delta_wh(consumer_ids, start_ts, end_ts)
    savings  = calc.savings_eur(produced)

    json_response(
      date:               today.to_s,
      produced_wh_today:  produced,
      consumed_wh_today:  consumed,
      savings_eur_today:  savings,
    )
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

    json_response(days: days, series: series)
  end

  get "/api/live" do
    threshold = settings.stale_threshold_seconds
    now       = Time.now.to_i

    plugs = settings.config.plugs.map do |plug|
      latest = settings.db[:samples].where(plug_id: plug.id).order(Sequel.desc(:ts)).first
      online = !latest.nil? && (now - latest[:ts]) <= threshold
      {
        id:           plug.id,
        name:         plug.name,
        role:         plug.role,
        online:       online,
        apower_w:     online ? latest[:apower_w] : nil,
        last_seen_ts: latest&.dig(:ts),
      }
    end

    json_response(plugs: plugs, now_ts: now)
  end
end
