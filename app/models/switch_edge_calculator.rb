# Pure edge computation: no I/O, no clock. Windows only need to respond to
# plug_id, on_at, off_at and days (SwitchWindow records or plain structs).
class SwitchEdgeCalculator
  Edge = Struct.new(:plug_id, :action, :at, keyword_init: true)

  # Total order for simultaneous edges: :off sorts before :on, so that
  # "last edge wins" resolves a tie in favor of switching on.
  ACTION_ORDER = { off: 0, on: 1 }.freeze

  def initialize(windows:, timezone: Time.zone)
    @windows = windows
    @tz      = timezone
  end

  # All edges with from < at <= to, ascending by time.
  def edges_between(from, to)
    return [] if to <= from

    first_date = from.in_time_zone(@tz).to_date - 1  # catches off edges of midnight-crossers
    last_date  = to.in_time_zone(@tz).to_date
    (first_date..last_date)
      .flat_map { |date| edges_for_date(date) }
      .select { |e| e.at > from && e.at <= to }
      .sort_by { |e| [ e.at, ACTION_ORDER[e.action] ] }
  end

  # At most one edge per plug: the latest within the interval.
  def latest_edge_per_plug(from, to)
    edges_between(from, to).group_by(&:plug_id).map { |_, edges| edges.last }
  end

  private

  def edges_for_date(date)
    @windows.select { |w| w.days.include?(date.cwday) }.flat_map do |w|
      off_date = w.on_at > w.off_at ? date + 1 : date
      [
        Edge.new(plug_id: w.plug_id, action: :on,  at: local_time(date, w.on_at)),
        Edge.new(plug_id: w.plug_id, action: :off, at: local_time(off_date, w.off_at))
      ]
    end
  end

  def local_time(date, minutes)
    @tz.local(date.year, date.month, date.day, minutes / 60, minutes % 60)
  end
end
