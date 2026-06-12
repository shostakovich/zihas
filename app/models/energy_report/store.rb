class EnergyReport
  # All database access for report building.
  class Store
    def latest_aggregate_date
      value = DailyTotal.maximum(:date)
      value.present? ? Date.iso8601(value) : nil
    end

    def daily_rows(start_date, end_date)
      DailyTotal.where(date: start_date.to_s..end_date.to_s).to_a
    end

    def daily_summaries(start_date, end_date)
      DailyEnergySummary.where(date: start_date.to_s..end_date.to_s).index_by(&:date)
    end

    def sample_rows(start_ts, end_ts)
      Sample5min.where(bucket_ts: start_ts...end_ts).order(:bucket_ts).to_a
    end

    def daily_totals_for_plug(plug_id, dates)
      DailyTotal.where(plug_id: plug_id, date: dates).index_by(&:date)
    end
  end
end