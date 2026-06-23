class SolakonHistory
  RANGES = {
    "24h" => 24.hours,
    "7d" => 7.days,
    "30d" => 30.days
  }.freeze

  # Longest gap between two snapshots we still integrate over. Snapshots arrive
  # every 2 min; capping at 5 min keeps monitoring downtime from inflating the
  # Außensteckdose energy totals (trapezoidal integration would otherwise treat
  # a multi-hour gap as one giant interval).
  OUTLET_MAX_GAP_S = 300

  def initialize(range_key:, now: Time.current)
    @range_key = RANGES.key?(range_key) ? range_key : "24h"
    @now = now
  end

  def payload
    rows = SolakonSnapshot.in_range(from: from_time, to: @now).to_a
    return empty_payload if rows.empty?

    {
      range: @range_key,
      chart: chart_payload(rows),
      balance_rows: balance_rows(rows),
      message: nil
    }
  end

  private

  def from_time
    @now - RANGES.fetch(@range_key)
  end

  def empty_payload
    {
      range: @range_key,
      chart: {
        labels: [],
        datasets: [
          { label: "PV", data: [] },
          { label: "Akku", data: [] },
          { label: "Außensteckdose", data: [] },
          { label: "0 W", data: [] }
        ]
      },
      balance_rows: [],
      message: "Keine Solakon-Historie"
    }
  end

  def chart_payload(rows)
    {
      labels: rows.map { |row| label_for(row.taken_at) },
      datasets: [
        { label: "PV", data: rows.map { |row| (row.pv1_power_w.to_f + row.pv2_power_w.to_f).round(1) } },
        { label: "Akku", data: rows.map { |row| row.battery_power_w.to_f.round(1) } },
        { label: "Außensteckdose", data: rows.map { |row| outlet_power_w(row).round(1) } },
        { label: "0 W", data: rows.map { 0 } }
      ]
    }
  end


  def outlet_power_w(row)
    return row.active_power_w.to_f if row.active_power_w.present?

    nearest = SolakonReading
      .where(taken_at: (row.taken_at - 2.minutes)..(row.taken_at + 2.minutes))
      .order(Arel.sql("ABS(strftime('%s', taken_at) - #{row.taken_at.to_i})"))
      .first
    nearest&.active_power_w.to_f
  end

  def label_for(time)
    @range_key == "24h" ? time.strftime("%H:%M") : time.strftime("%d.%m.")
  end

  def balance_rows(rows)
    first = rows.first
    last = rows.last
    deltas = {
      pv: delta(first.pv_total_kwh, last.pv_total_kwh),
      charge: delta(first.battery_charge_total_kwh, last.battery_charge_total_kwh),
      discharge: delta(first.battery_discharge_total_kwh, last.battery_discharge_total_kwh)
    }
    # No grid meter on this unit, so 39613/39617/grid_power read 0. We reconstruct
    # the inverter's AC-port exchange instead, by integrating the signed
    # Außensteckdose power (active_power_w) over the snapshots — the same series
    # that draws the blue chart line. This is the inverter's feed/draw at the
    # outdoor socket, NOT whole-house grid flow (household consumption is unmeasured).
    outlet = outlet_energy(rows)
    max = [
      deltas.values.max.to_f,
      outlet.fetch(:delivered_kwh),
      outlet.fetch(:drawn_kwh),
      outlet.fetch(:avg_w).abs / 1000.0,
      0.001
    ].max

    [
      row("PV-Erzeugung", deltas.fetch(:pv), max, :solar),
      row("Akku geladen", deltas.fetch(:charge), max, :battery),
      row("Akku entladen", deltas.fetch(:discharge), max, :battery),
      row("Ins Hausnetz geliefert", outlet.fetch(:delivered_kwh), max, :grid),
      row("Aus Hausnetz gezogen", outlet.fetch(:drawn_kwh), max, :grid),
      {
        label: "Ø Außensteckdose",
        value: "#{format_decimal(outlet.fetch(:avg_w).round)} W",
        share: ((outlet.fetch(:avg_w).abs / 1000.0) / max * 100).round(1),
        role: "grid"
      }
    ]
  end

  # Trapezoidal integration of the signed Außensteckdose power across snapshots.
  # delivered_kwh = energy fed into the house net (P > 0), drawn_kwh = energy
  # pulled from it (P < 0), avg_w = time-weighted mean power (signed).
  def outlet_energy(rows)
    delivered_wh = 0.0
    drawn_wh = 0.0
    total_s = 0.0
    rows.each_cons(2) do |a, b|
      dt = (b.taken_at - a.taken_at).to_f
      next unless dt.positive?

      dt = [ dt, OUTLET_MAX_GAP_S ].min
      avg_p = (outlet_power_w(a) + outlet_power_w(b)) / 2.0
      hours = dt / 3600.0
      delivered_wh += [ avg_p, 0.0 ].max * hours
      drawn_wh += [ -avg_p, 0.0 ].max * hours
      total_s += dt
    end

    signed_wh = delivered_wh - drawn_wh
    {
      delivered_kwh: (delivered_wh / 1000.0).round(2),
      drawn_kwh: (drawn_wh / 1000.0).round(2),
      avg_w: total_s.positive? ? signed_wh * 3600.0 / total_s : 0.0
    }
  end

  def delta(first_value, last_value)
    [ last_value.to_f - first_value.to_f, 0.0 ].max.round(2)
  end

  def row(label, kwh, max, role)
    { label: label, value: "#{format_decimal(kwh)} kWh", share: (kwh / max * 100).round(1), role: role.to_s }
  end

  def format_decimal(value)
    format("%.2f", value).sub(".", ",")
  end
end
