require "test_helper"

class ScheduleTickJobTest < ActiveSupport::TestCase
  setup do
    SchedulerState.delete_all
    SwitchWindow.delete_all
    SwitchCommand.delete_all
    @calls = []
    @recorder = ->(plug, action, source:, mqtt_config:) { @calls << [ plug.id, action, source ] }
  end

  def monday_18_05 = Time.zone.local(2026, 6, 15, 18, 5)

  def create_window(on_at: 1080, off_at: 1380, days: [ 1 ], plug_id: "fridge", enabled: true)
    SwitchWindow.create!(plug_id: plug_id, on_at: on_at, off_at: off_at, days: days, enabled: enabled)
  end

  test "first run only initializes the watermark" do
    create_window
    travel_to monday_18_05 do
      PlugCommander.stub :switch, @recorder do
        ScheduleTickJob.perform_now
      end
      assert_equal Time.current, SchedulerState.last_tick_at
    end
    assert_empty @calls
  end

  test "fires the edge between watermark and now and advances the watermark" do
    create_window  # Mo 18:00-23:00, on edge at 18:00
    travel_to monday_18_05 do
      SchedulerState.advance!(10.minutes.ago)
      PlugCommander.stub :switch, @recorder do
        ScheduleTickJob.perform_now
      end
      assert_equal [ [ "fridge", :on, :schedule ] ], @calls
      assert_equal Time.current, SchedulerState.last_tick_at
    end
  end

  test "collapses multiple missed edges to the latest per plug" do
    create_window(on_at: 1080, off_at: 1083)  # Mo 18:00-18:03 -> on@18:00, off@18:03
    travel_to monday_18_05 do
      SchedulerState.advance!(10.minutes.ago)
      PlugCommander.stub :switch, @recorder do
        ScheduleTickJob.perform_now
      end
      assert_equal [ [ "fridge", :off, :schedule ] ], @calls
    end
  end

  test "skips the edge when a manual command came after the edge time" do
    create_window  # on edge 18:00
    travel_to monday_18_05 do
      SwitchCommand.create!(plug_id: "fridge", action: "off", source: "manual",
                            created_at: Time.zone.local(2026, 6, 15, 18, 1))
      SchedulerState.advance!(10.minutes.ago)
      PlugCommander.stub :switch, @recorder do
        ScheduleTickJob.perform_now
      end
      assert_empty @calls
      assert_equal Time.current, SchedulerState.last_tick_at
    end
  end

  test "ignores disabled windows and windows of unknown plugs" do
    create_window(enabled: false)
    create_window(plug_id: "gone")
    travel_to monday_18_05 do
      SchedulerState.advance!(10.minutes.ago)
      PlugCommander.stub :switch, @recorder do
        ScheduleTickJob.perform_now
      end
    end
    assert_empty @calls
  end

  test "watermark stays put when a publish fails" do
    create_window
    failing = ->(*, **) { raise PlugCommander::Error, "broker down" }
    travel_to monday_18_05 do
      watermark = 10.minutes.ago
      SchedulerState.advance!(watermark)
      PlugCommander.stub :switch, failing do
        ScheduleTickJob.perform_now
      end
      assert_equal watermark, SchedulerState.last_tick_at
    end
  end
end
