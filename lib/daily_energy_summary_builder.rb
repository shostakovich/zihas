require "date"
require "tzinfo"

class DailyEnergySummaryBuilder
  BUCKET_SECONDS = 300

  def initialize(plugs:, timezone:)
    @plug_role = plugs.each_with_object({}) { |p, h| h[p.id] = p.role }
    @timezone  = timezone.is_a?(TZInfo::Timezone) ? timezone : TZInfo::Timezone.get(timezone)
  end

  def build(date_s)
    start_ts = @timezone.local_to_utc(Time.parse("#{date_s} 00:00:00")).to_i
    end_ts   = start_ts + 86_400

    rows = Sample5min.where(bucket_ts: start_ts..(end_ts - 1)).to_a

    produced_wh      = 0.0
    consumed_wh      = 0.0
    self_consumed_wh = 0.0

    rows.group_by(&:bucket_ts).each_value do |bucket_rows|
      prod_wh = 0.0
      cons_wh = 0.0
      bucket_rows.each do |row|
        case @plug_role[row.plug_id]
        when :producer then prod_wh += row.energy_delta_wh
        when :consumer then cons_wh += row.energy_delta_wh
        end
      end
      produced_wh      += prod_wh
      consumed_wh      += cons_wh
      self_consumed_wh += [ prod_wh, cons_wh ].min
    end

    {
      produced_wh:      produced_wh,
      consumed_wh:      consumed_wh,
      self_consumed_wh: self_consumed_wh
    }
  end
end
