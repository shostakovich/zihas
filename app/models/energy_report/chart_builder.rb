class EnergyReport
  # Chart payload builders (daily + detail) including weather overlay.
  class ChartBuilder
    def initialize(plugs:, timezone:, store:, weather_loader: nil)
      @plugs = plugs
      @timezone = timezone
      @store = store
      @weather_loader = weather_loader
    end

    def payload(daily_points:, rows:, range:, detail_range:)
      {
        daily: daily_chart_payload(daily_points),
        detail: detail_chart_payload(rows, detail_range.fetch(:start_date), detail_range.fetch(:end_date))
      }.tap do |payload|
        attach_daily_weather!(payload[:daily], range.fetch(:start_date), range.fetch(:end_date))
        attach_detail_weather!(payload[:detail], detail_range.fetch(:start_date), detail_range.fetch(:end_date))
      end
    end

    private

    def daily_chart_payload(daily_points)
      {
        labels: daily_points.map { |point| Date.iso8601(point.fetch(:date)).strftime("%d.%m.") },
        produced_kwh: daily_points.map { |point| point.fetch(:produced_kwh) },
        consumed_kwh: daily_points.map { |point| point.fetch(:consumed_kwh) },
        balance_kwh: daily_points.map { |point| point.fetch(:balance_kwh) },
        consumer_series: consumer_daily_series(daily_points.map { |point| point.fetch(:date) }),
        ratios: daily_points.map { |point| ratio_point(point) }
      }
    end

    def ratio_point(point)
      if point.fetch(:covered)
        {
          date: point.fetch(:date),
          autarky_pct:          ratio_pct(point.fetch(:self_consumed_kwh), point.fetch(:consumed_kwh)),
          self_consumption_pct: ratio_pct(point.fetch(:self_consumed_kwh), point.fetch(:produced_kwh))
        }
      else
        { date: point.fetch(:date), autarky_pct: nil, self_consumption_pct: nil }
      end
    end

    def ratio_pct(numerator, denominator)
      return 0.0 if denominator.nil? || denominator.zero?
      ((numerator.to_f / denominator) * 100).round(1)
    end

    def consumer_daily_series(labels)
      @plugs
        .select { |plug| plug.role == :consumer }
        .map do |plug|
          rows_by_date = @store.daily_totals_for_plug(plug.id, labels)
          {
            plug_id: plug.id,
            name: plug.name,
            data: labels.map do |date|
              row = rows_by_date[date]
              row ? kwh(row.energy_wh) : 0.0
            end
          }
        end
    end

    def detail_chart_payload(rows, start_date, end_date)
      return daily_power_detail_chart_payload(rows, start_date, end_date) if (end_date - start_date).to_i > 6

      sample_detail_chart_payload(start_date, end_date)
    end

    def sample_detail_chart_payload(start_date, end_date)
      start_ts = local_midnight_utc(start_date)
      end_ts = local_midnight_utc(end_date + 1)
      rows = @store.sample_rows(start_ts, end_ts)
      timestamps = rows.map(&:bucket_ts).uniq.sort
      multi_day = start_date != end_date

      series = @plugs.map do |plug|
        plug_rows = rows.select { |row| row.plug_id == plug.id }
        points_by_ts = plug_rows.index_by(&:bucket_ts)
        {
          plug_id: plug.id,
          name: plug.name,
          role: plug.role.to_s,
          data: timestamps.map do |ts|
            row = points_by_ts[ts]
            row ? watt_value(row.avg_power_w, plug.role) : nil
          end
        }
      end.select { |series_row| series_row.fetch(:data).any?(&:present?) }

      {
        chart_type: "line",
        labels: timestamps.map { |ts| detail_label(ts, multi_day) },
        series: series,
        _timestamps: timestamps
      }
    end

    def daily_power_detail_chart_payload(rows, start_date, end_date)
      rows_by_plug_and_date = rows.group_by { |row| [ row.plug_id, row.date ] }
      dates = (start_date..end_date).to_a

      series = @plugs.map do |plug|
        {
          plug_id: plug.id,
          name: plug.name,
          role: plug.role.to_s,
          data: dates.map do |date|
            row = rows_by_plug_and_date[[ plug.id, date.to_s ]]&.first
            row ? average_power_w(row.energy_wh, plug.role) : nil
          end
        }
      end.select { |series_row| series_row.fetch(:data).any?(&:present?) }

      {
        chart_type: "bar",
        labels: dates.map { |date| date.strftime("%d.%m.") },
        series: series
      }
    end

    def local_midnight_utc(date)
      local_midnight = Time.new(date.year, date.month, date.day, 0, 0, 0)
      @timezone.local_to_utc(local_midnight).to_i
    end

    def detail_label(ts, multi_day)
      local_time = @timezone.utc_to_local(Time.at(ts).utc)
      local_time.strftime(multi_day ? "%d.%m. %H:%M" : "%H:%M")
    end

    def plug_role(plug_id)
      @plug_by_id ||= @plugs.index_by(&:id)
      @plug_by_id[plug_id]&.role
    end

    def watt_value(value, role)
      role == :producer ? value.abs.round(1) : value.round(1)
    end

    def average_power_w(energy_wh, role)
      watt_value(energy_wh.to_f / 24.0, role)
    end

    def attach_daily_weather!(daily_payload, start_date, end_date)
      return unless @weather_loader

      daily = @weather_loader.daily(start_date, end_date)
      return if daily.empty?

      show_icons = (end_date - start_date).to_i + 1 <= 7
      dates = (start_date..end_date).map(&:to_s)
      icons = if show_icons
        dates.map do |d|
          entry = daily[d]
          entry ? { asset_name: entry[:asset_name], alt: entry[:alt] } : nil
        end
      else
        []
      end

      daily_payload[:weather] = {
        solar_kwh_per_m2: dates.map { |d| daily.dig(d, :solar_kwh_per_m2) },
        icons: icons
      }
    end

    def attach_detail_weather!(detail_payload, start_date, end_date)
      timestamps = detail_payload.delete(:_timestamps) || []

      return unless @weather_loader
      return unless detail_payload[:chart_type] == "line"
      return if timestamps.empty?

      hourly = @weather_loader.hourly(start_date, end_date)
      return if hourly.empty?

      by_hour = hourly.index_by { |p| Time.at(p[:ts]).utc.to_i }

      solar = timestamps.map { |ts| by_hour.dig(hour_bucket_for(ts), :solar_w_per_m2) }

      icons = if start_date == end_date
        detail_icons_hourly(timestamps, by_hour)
      else
        detail_icons_one_per_day(timestamps, by_hour)
      end

      detail_payload[:weather] = {
        solar_w_per_m2: solar,
        icons: icons
      }
    end

    def detail_icons_hourly(timestamps, by_hour)
      timestamps.map.with_index do |ts, idx|
        next nil unless ts % 3600 == 0
        point = by_hour[hour_bucket_for(ts)]
        next nil unless point
        { label_index: idx, asset_name: point[:asset_name], alt: point[:alt] }
      end.compact
    end

    def detail_icons_one_per_day(timestamps, by_hour)
      timestamps.map.with_index do |ts, idx|
        local = @timezone.utc_to_local(Time.at(ts).utc)
        next nil unless local.hour == 12 && local.min == 0
        point = by_hour[hour_bucket_for(ts)]
        next nil unless point
        { label_index: idx, asset_name: point[:asset_name], alt: point[:alt] }
      end.compact
    end

    def hour_bucket_for(ts)
      ts - (ts % 3600)
    end

    def kwh(wh)
      (wh.to_f / 1000.0).round(3)
    end
  end
end
