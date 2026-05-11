class TrmnlPayloadBuilder
  BUCKET_SECONDS = 300
  HOURS          = 24

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
    ev, es     = hourly_arrays

    {
      "merge_variables" => {
        "pv_kwh"     => pv_kwh,
        "cons_kwh"   => cons_kwh,
        "bilanz_kwh" => bilanz_kwh,
        "autarky"    => autarky,
        "self_use"   => self_use,
        "ev"         => ev,
        "es"         => es,
      },
    }
  end

  private

  def hourly_arrays
    start_ts, end_ts = window_bounds
    rows = bucket_rows(start_ts, end_ts)
    role_by_id = @config.plugs.each_with_object({}) { |p, h| h[p.id] = p.role }

    ev = Array.new(HOURS, 0.0)
    pv = Array.new(HOURS, 0.0)
    rows.group_by { |r| r["bucket_ts"] }.each do |bucket_ts, bucket_rows|
      prod_w = 0.0
      cons_w = 0.0
      bucket_rows.each do |row|
        case role_by_id[row["plug_id"]]
        when :producer then prod_w += row["avg_w"].to_f.abs
        when :consumer then cons_w += row["avg_w"].to_f
        end
      end
      hour_idx = ((bucket_ts - start_ts) / 3600).to_i
      next if hour_idx < 0 || hour_idx >= HOURS

      bucket_h = BUCKET_SECONDS / 3600.0
      pv[hour_idx] += prod_w * bucket_h
      ev[hour_idx] += [ prod_w, cons_w ].min * bucket_h
    end

    ev_int = ev.map(&:round)
    es_int = pv.zip(ev).map { |p, e| [ p - e, 0 ].max.round }
    [ ev_int, es_int ]
  end

  def window_bounds
    now_utc   = Time.now.utc
    local_now = @tz.utc_to_local(now_utc)
    hour_floor = Time.new(local_now.year, local_now.month, local_now.day, local_now.hour, 0, 0)
    end_ts   = @tz.local_to_utc(hour_floor).to_i + 3600
    start_ts = end_ts - HOURS * 3600
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
end
