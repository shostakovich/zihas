require "sinatra/base"
require "json"
require "config_loader"
require "db"

class Web < Sinatra::Base
  configure do
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
