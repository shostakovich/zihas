require "test_helper"

class SwitchEdgeCalculatorTest < ActiveSupport::TestCase
  # Pure unit tests: windows are plain structs, no DB.
  W = Struct.new(:plug_id, :on_at, :off_at, :days, keyword_init: true)

  def tz = Time.zone

  def calc(*windows)
    SwitchEdgeCalculator.new(windows: windows)
  end

  test "fires on and off edges on configured weekdays" do
    c = calc(W.new(plug_id: "lamp", on_at: 1080, off_at: 1380, days: [ 1 ]))  # Mo 18:00-23:00
    edges = c.edges_between(tz.local(2026, 6, 15, 0, 0), tz.local(2026, 6, 16, 0, 0))
    assert_equal 2, edges.length
    assert_equal [ :on, :off ], edges.map(&:action)
    assert_equal tz.local(2026, 6, 15, 18, 0), edges.first.at
    assert_equal tz.local(2026, 6, 15, 23, 0), edges.last.at
    assert_equal "lamp", edges.first.plug_id
  end

  test "skips days not in the weekday list" do
    c = calc(W.new(plug_id: "lamp", on_at: 1080, off_at: 1380, days: [ 2 ]))  # Di only
    edges = c.edges_between(tz.local(2026, 6, 15, 0, 0), tz.local(2026, 6, 16, 0, 0))
    assert_empty edges
  end

  test "midnight-crossing window puts the off edge on the next day" do
    c = calc(W.new(plug_id: "lamp", on_at: 1320, off_at: 360, days: [ 1 ]))  # Mo 22:00-06:00
    edges = c.edges_between(tz.local(2026, 6, 15, 0, 0), tz.local(2026, 6, 17, 0, 0))
    assert_equal tz.local(2026, 6, 15, 22, 0), edges.first.at
    assert_equal tz.local(2026, 6, 16, 6, 0),  edges.last.at
  end

  test "off edge of a window started the previous day is found" do
    c = calc(W.new(plug_id: "lamp", on_at: 1320, off_at: 360, days: [ 1 ]))
    # Interval starts Tuesday 05:00 — only the off edge (Tue 06:00) is inside.
    edges = c.edges_between(tz.local(2026, 6, 16, 5, 0), tz.local(2026, 6, 16, 7, 0))
    assert_equal 1, edges.length
    assert_equal :off, edges.first.action
    assert_equal tz.local(2026, 6, 16, 6, 0), edges.first.at
  end

  test "interval is exclusive at from, inclusive at to" do
    c = calc(W.new(plug_id: "lamp", on_at: 1080, off_at: 1380, days: [ 1 ]))
    on_time = tz.local(2026, 6, 15, 18, 0)
    assert_empty c.edges_between(on_time, tz.local(2026, 6, 15, 18, 30))
    edges = c.edges_between(tz.local(2026, 6, 15, 17, 0), on_time)
    assert_equal [ on_time ], edges.map(&:at)
  end

  test "empty or inverted interval returns no edges" do
    c = calc(W.new(plug_id: "lamp", on_at: 1080, off_at: 1380, days: [ 1 ]))
    t = tz.local(2026, 6, 15, 12, 0)
    assert_empty c.edges_between(t, t)
    assert_empty c.edges_between(t, t - 1.hour)
  end

  test "latest_edge_per_plug collapses to the most recent edge per plug" do
    c = calc(
      W.new(plug_id: "lamp", on_at: 1080, off_at: 1140, days: [ 1 ]),  # Mo 18:00-19:00
      W.new(plug_id: "fan",  on_at: 1100, off_at: 1380, days: [ 1 ])   # Mo 18:20-23:00
    )
    edges = c.latest_edge_per_plug(tz.local(2026, 6, 15, 17, 0), tz.local(2026, 6, 15, 20, 0))
    assert_equal 2, edges.length
    lamp = edges.find { |e| e.plug_id == "lamp" }
    fan  = edges.find { |e| e.plug_id == "fan" }
    assert_equal :off, lamp.action  # 19:00 beats 18:00
    assert_equal :on,  fan.action   # only 18:20 inside (off is 23:00, outside)
  end

  test "on edge wins a same-timestamp tie in latest_edge_per_plug" do
    c = calc(
      W.new(plug_id: "lamp", on_at: 1080, off_at: 1140, days: [ 1 ]),  # Mo 18:00-19:00
      W.new(plug_id: "lamp", on_at: 1140, off_at: 1200, days: [ 1 ])   # Mo 19:00-20:00
    )
    edges = c.latest_edge_per_plug(tz.local(2026, 6, 15, 17, 0), tz.local(2026, 6, 15, 19, 0))
    assert_equal 1, edges.length
    assert_equal :on, edges.first.action
    # And edges_between orders :off before :on at the same instant
    all = c.edges_between(tz.local(2026, 6, 15, 17, 0), tz.local(2026, 6, 15, 19, 0))
    assert_equal [ :on, :off, :on ], all.map(&:action)
  end

  test "spring-forward gap shifts the edge forward" do
    # 2026-03-29 (Sunday) 02:00 -> 03:00 in Europe/Berlin; 02:30 does not exist.
    c = calc(W.new(plug_id: "lamp", on_at: 150, off_at: 240, days: [ 7 ]))  # So 02:30-04:00
    edges = c.edges_between(tz.local(2026, 3, 29, 0, 0), tz.local(2026, 3, 29, 12, 0))
    assert_equal 2, edges.length
    assert_equal 3, edges.first.at.hour
    assert_equal 30, edges.first.at.min
  end
end
