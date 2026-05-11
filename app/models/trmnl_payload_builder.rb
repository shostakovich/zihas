class TrmnlPayloadBuilder
  BUCKET_SECONDS = 1800
  BUCKETS        = 48

  def initialize(config:)
    @config = config
    @tz     = TZInfo::Timezone.get(config.timezone)
  end

  def build
    summary    = EnergySummary.new(config: @config).compute_today
    pv_kwh     = (summary.produced_wh.to_f / 1000.0).round(2)
    cons_kwh   = (summary.consumed_wh.to_f / 1000.0).round(2)
    bilanz_kwh = (pv_kwh - cons_kwh).round(2)
    autarky    = (summary.autarky_ratio          * 100).round
    self_use   = (summary.self_consumption_ratio * 100).round
    pv_w, cons_w = power_series
    ts = sample_ts(*window_bounds)

    {
      "merge_variables" => {
        "ts"         => ts,
        "pv_kwh"     => pv_kwh,
        "cons_kwh"   => cons_kwh,
        "bilanz_kwh" => bilanz_kwh,
        "autarky"    => autarky,
        "self_use"   => self_use,
        "pv_w"       => pv_w,
        "cons_w"     => cons_w
      }
    }
  end

  private

  def power_series
    start_ts, end_ts = window_bounds
    rows = bucket_rows(start_ts, end_ts)
    role_by_id = @config.plugs.each_with_object({}) { |p, h| h[p.id] = p.role }

    pv   = Array.new(BUCKETS, 0.0)
    cons = Array.new(BUCKETS, 0.0)
    rows.each do |row|
      idx = ((row["bucket_ts"] - start_ts) / BUCKET_SECONDS).to_i
      next if idx < 0 || idx >= BUCKETS

      case role_by_id[row["plug_id"]]
      when :producer then pv[idx]   += row["avg_w"].to_f.abs
      when :consumer then cons[idx] += row["avg_w"].to_f
      end
    end

    [ pv.map(&:round), cons.map(&:round) ]
  end

  def window_bounds
    now_utc    = Time.now.utc
    local_now  = @tz.utc_to_local(now_utc)
    hour_floor = Time.new(local_now.year, local_now.month, local_now.day, local_now.hour, 0, 0)
    end_ts     = @tz.local_to_utc(hour_floor).to_i + 3600
    start_ts   = end_ts - BUCKETS * BUCKET_SECONDS
    [ start_ts, end_ts ]
  end

  def bucket_rows(start_ts, end_ts)
    plug_ids = @config.plugs.map(&:id)
    return [] if plug_ids.empty?

    ActiveRecord::Base.connection.exec_query(
      ActiveRecord::Base.sanitize_sql_array([
        <<~SQL, plug_ids, start_ts, end_ts
          SELECT plug_id,
                 (ts / #{BUCKET_SECONDS}) * #{BUCKET_SECONDS} AS bucket_ts,
                 AVG(apower_w) AS avg_w
            FROM samples
           WHERE plug_id IN (?) AND ts >= ? AND ts < ?
           GROUP BY plug_id, bucket_ts
        SQL
      ])
    ).to_a
  end

  def sample_ts(start_ts, end_ts)
    plug_ids = @config.plugs.map(&:id)
    return Time.now.to_i if plug_ids.empty?

    max_ts = Sample.where(plug_id: plug_ids, ts: start_ts...end_ts).maximum(:ts)
    max_ts || Time.now.to_i
  end
end
