require "test_helper"

class SolakonMonitorJobTest < ActiveSupport::TestCase
  class FakeClient
    attr_reader :calls

    def initialize(state: nil, fail: false)
      @state = state
      @fail = fail
      @calls = []
    end

    def read_state
      @calls << :read_state
      raise SolakonClient::Error, "down" if @fail

      @state
    end
  end

  Sol = Struct.new(:host, :port, :unit_id, :monitoring_enabled, :control_enabled,
                   :stale_after_s, keyword_init: true)
  Cfg = Struct.new(:solakon, keyword_init: true)

  setup do
    SolakonReading.delete_all
  end

  def config(monitoring_enabled: true, control_enabled: false, solakon: true)
    Cfg.new(
      solakon: (
        Sol.new(
          host: "h",
          port: 502,
          unit_id: 1,
          monitoring_enabled: monitoring_enabled,
          control_enabled: control_enabled,
          stale_after_s: 120
        ) if solakon
      )
    )
  end

  def state
    SolakonClient::State.new(
      battery_soc: 55,
      active_power_w: 123,
      pv_power_w: 456,
      battery_power_w: -78
    )
  end

  def run_job(client:, cfg: config, now: Time.zone.local(2026, 6, 18, 12, 0, 0), &block)
    ConfigLoader.stub(:app_config, cfg) do
      if block
        ZeroExportTickJob.stub(:perform_now, block) do
          SolakonMonitorJob.new.perform(client: client, now: now)
        end
      else
        SolakonMonitorJob.new.perform(client: client, now: now)
      end
    end
  end

  test "persists reading when monitoring_enabled true" do
    now = Time.zone.local(2026, 6, 18, 12, 0, 0)
    client = FakeClient.new(state: state)

    assert_difference -> { SolakonReading.count }, 1 do
      run_job(client: client, now: now)
    end

    reading = SolakonReading.last
    assert_equal [ :read_state ], client.calls
    assert_equal now, reading.taken_at
    assert_equal 123, reading.active_power_w
    assert_equal 456, reading.pv_power_w
    assert_equal(-78, reading.battery_power_w)
    assert_equal 55, reading.battery_soc_pct
  end

  test "does not read or persist when monitoring_enabled false" do
    client = FakeClient.new(state: state)

    assert_no_difference -> { SolakonReading.count } do
      run_job(client: client, cfg: config(monitoring_enabled: false))
    end

    assert_empty client.calls
  end

  test "read failure does not persist and does not control" do
    client = FakeClient.new(fail: true)
    control_calls = []

    assert_no_difference -> { SolakonReading.count } do
      assert_nothing_raised do
        run_job(client: client, cfg: config(control_enabled: true), &->(state:) { control_calls << state })
      end
    end

    assert_equal [ :read_state ], client.calls
    assert_empty control_calls
  end

  test "successful read with control_enabled true triggers zero export tick with state" do
    current_state = state
    client = FakeClient.new(state: current_state)
    control_calls = []

    run_job(client: client, cfg: config(control_enabled: true), &->(state:) { control_calls << state })

    assert_equal [ current_state ], control_calls
  end
end
