require "test_helper"

class ZeroExportTickJobTest < ActiveSupport::TestCase
  class FakeClient
    attr_reader :calls
    def initialize(state: nil, fail: false)
      @state = state
      @fail  = fail
      @calls = []
    end

    # The job drives a tick through control_tick!: a Modbus failure surfaces
    # here (the read happens first), otherwise the block decides the setpoint.
    def control_tick!(min_soc:)
      raise SolakonClient::Error, "down" if @fail
      power = yield(@state)
      @calls << [ :apply, power, min_soc ]
      @state
    end

    def release_control! = (@calls << :release)
  end

  Plug = Struct.new(:id, :role, :name, keyword_init: true)
  Sol  = Struct.new(:host, :port, :unit_id, :enabled, :stale_after_s, keyword_init: true)
  Cfg  = Struct.new(:plugs, :solakon, keyword_init: true)

  def config(enabled: true, solakon: true)
    sol = solakon ? Sol.new(host: "h", port: 502, unit_id: 1, enabled: enabled, stale_after_s: 120) : nil
    Cfg.new(plugs: [ Plug.new(id: "fridge", role: :consumer, name: "Kühlschrank") ], solakon: sol)
  end

  setup do
    Sample.delete_all
    @cache = ActiveSupport::Cache::MemoryStore.new
  end

  def run_job(client:, now: Time.at(1_000_000), cfg: config)
    Rails.stub(:cache, @cache) do
      ConfigLoader.stub(:app_config, cfg) do
        ZeroExportTickJob.new.perform(client: client, reader_now: now)
      end
    end
  end

  def healthy_state
    SolakonClient::State.new(battery_soc: 55, active_power_w: 250, pv_power_w: 0, battery_power_w: 0)
  end

  def state_with(soc:, pv: 100)
    SolakonClient::State.new(battery_soc: soc, active_power_w: 0, pv_power_w: pv, battery_power_w: 0)
  end

  test "applies control derived from measured consumption, with min_soc guard" do
    now = Time.at(1_000_000)
    Sample.create!(plug_id: "fridge", ts: now.to_i - 5, apower_w: 250, aenergy_wh: 1)
    client = FakeClient.new(state: healthy_state)
    run_job(client: client, now: now)
    assert_equal [ [ :apply, 250, 10 ] ], client.calls
  end

  test "fresh low consumption is not overridden by a stale cached floor" do
    now = Time.at(1_000_000)
    Sample.create!(plug_id: "fridge", ts: now.to_i - 5, apower_w: 20, aenergy_wh: 1)
    @cache.write(ZeroExportTickJob::FLOOR_CACHE_KEY, 200.0) # stale, high cached floor
    client = FakeClient.new(state: healthy_state)
    run_job(client: client, now: now)
    assert_equal [ [ :apply, 20, 10 ] ], client.calls # follows fresh load, not the floor
  end

  test "falls back to the floor when no fresh samples are available" do
    now = Time.at(1_000_000)
    # only a stale sample exists -> consumption unknown -> use floor (146)
    Sample.create!(plug_id: "fridge", ts: now.to_i - 600, apower_w: 146, aenergy_wh: 1)
    client = FakeClient.new(state: healthy_state)
    run_job(client: client, now: now)
    assert_equal [ [ :apply, 146, 10 ] ], client.calls
  end

  test "recovery mode caps the setpoint so the battery charges instead of toggling" do
    now = Time.at(1_000_000)
    Sample.create!(plug_id: "fridge", ts: now.to_i - 5, apower_w: 170, aenergy_wh: 1)
    client = FakeClient.new(state: state_with(soc: 12, pv: 100))
    run_job(client: client, now: now)
    assert_equal [ [ :apply, 70, 10 ] ], client.calls # min(170, 100-30)
  end

  test "recovery hysteresis holds between the thresholds" do
    now = Time.at(1_000_000)
    Sample.create!(plug_id: "fridge", ts: now.to_i - 5, apower_w: 170, aenergy_wh: 1)
    run_job(client: FakeClient.new(state: state_with(soc: 12, pv: 100)), now: now) # enter recovery
    held = FakeClient.new(state: state_with(soc: 14, pv: 100))                      # between 13 and 15
    run_job(client: held, now: now)
    assert_equal [ [ :apply, 70, 10 ] ], held.calls # still recovery -> still capped
  end

  test "recovery exits at the upper threshold and resumes discharge" do
    now = Time.at(1_000_000)
    Sample.create!(plug_id: "fridge", ts: now.to_i - 5, apower_w: 170, aenergy_wh: 1)
    run_job(client: FakeClient.new(state: state_with(soc: 12, pv: 100)), now: now) # enter recovery
    exited = FakeClient.new(state: state_with(soc: 15, pv: 100))                    # >= 15 -> normal
    run_job(client: exited, now: now)
    assert_equal [ [ :apply, 170, 10 ] ], exited.calls # discharge allowed again, follows load
  end

  test "no-op when disabled" do
    client = FakeClient.new
    run_job(client: client, cfg: config(enabled: false))
    assert_empty client.calls
  end

  test "no-op when solakon not configured" do
    client = FakeClient.new
    run_job(client: client, cfg: config(solakon: false))
    assert_empty client.calls
  end

  test "a single failure does not raise or relinquish control" do
    now = Time.at(1_000_000)
    Sample.create!(plug_id: "fridge", ts: now.to_i - 5, apower_w: 250, aenergy_wh: 1)
    client = FakeClient.new(fail: true)
    assert_nothing_raised { run_job(client: client, now: now) }
    refute_includes client.calls, :release
  end

  test "relinquishes remote control after repeated failures" do
    now = Time.at(1_000_000)
    Sample.create!(plug_id: "fridge", ts: now.to_i - 5, apower_w: 250, aenergy_wh: 1)
    client = FakeClient.new(fail: true)
    3.times { run_job(client: client, now: now) }
    assert_equal 1, client.calls.count(:release)
  end

  test "a success resets the failure counter" do
    now = Time.at(1_000_000)
    Sample.create!(plug_id: "fridge", ts: now.to_i - 5, apower_w: 250, aenergy_wh: 1)

    failing = FakeClient.new(fail: true)
    2.times { run_job(client: failing, now: now) }   # 2 consecutive failures

    run_job(client: FakeClient.new(state: healthy_state), now: now) # success resets

    failing2 = FakeClient.new(fail: true)
    2.times { run_job(client: failing2, now: now) }  # only 2 again -> no release
    refute_includes failing2.calls, :release
  end
end
