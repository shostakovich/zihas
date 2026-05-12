require "test_helper"

class SensorPollJobTest < ActiveJob::TestCase
  def fake_config(switchbot:, sensors:)
    Struct.new(:switchbot, :sensors).new(switchbot, sensors)
  end

  def fake_sb(token:, secret:)
    Struct.new(:token, :secret).new(token, secret)
  end

  def fake_sensor(id, type)
    Struct.new(:id, :name, :type, :room).new(id, "name-#{id}", type, nil)
  end

  test "creates a SensorReading for each sensor" do
    config = fake_config(
      switchbot: fake_sb(token: "t", secret: "s"),
      sensors: [ fake_sensor("A", :meter_pro_co2), fake_sensor("B", :outdoor_meter) ]
    )

    fake_client = Object.new
    def fake_client.device_status(id)
      { temperature: 20.0, humidity: 50, co2: (id == "A" ? 600 : nil),
        battery_pct: 80, firmware_version: "V1", raw: {} }
    end

    ConfigLoader.stub(:load, config) do
      SwitchBotClient.stub(:new, fake_client) do
        SensorsBroadcaster.stub(:refresh, nil) do
          assert_difference "SensorReading.count", 2 do
            SensorPollJob.perform_now
          end
        end
      end
    end

    rows = SensorReading.order(:device_id)
    assert_equal "A", rows[0].device_id
    assert_equal 600, rows[0].co2
    assert_nil rows[1].co2
  end

  test "isolates per-sensor errors so the job continues" do
    config = fake_config(
      switchbot: fake_sb(token: "t", secret: "s"),
      sensors: [ fake_sensor("A", :meter_pro_co2), fake_sensor("B", :outdoor_meter) ]
    )

    fake_client = Object.new
    def fake_client.device_status(id)
      raise SwitchBotClient::Error, "boom" if id == "A"
      { temperature: 12.0, humidity: 60, co2: nil, battery_pct: 100, firmware_version: "V1", raw: {} }
    end

    ConfigLoader.stub(:load, config) do
      SwitchBotClient.stub(:new, fake_client) do
        SensorsBroadcaster.stub(:refresh, nil) do
          assert_difference "SensorReading.count", 1 do
            SensorPollJob.perform_now
          end
        end
      end
    end

    assert_equal "B", SensorReading.last.device_id
  end

  test "no-ops when switchbot config is missing" do
    config = fake_config(switchbot: nil, sensors: [])
    ConfigLoader.stub(:load, config) do
      assert_no_difference "SensorReading.count" do
        SensorPollJob.perform_now
      end
    end
  end

  test "broadcasts after polling" do
    config = fake_config(
      switchbot: fake_sb(token: "t", secret: "s"),
      sensors: [ fake_sensor("A", :meter_pro_co2) ]
    )
    fake_client = Object.new
    def fake_client.device_status(_)
      { temperature: 1, humidity: 1, co2: 1, battery_pct: 1, firmware_version: "V", raw: {} }
    end

    called = false
    ConfigLoader.stub(:load, config) do
      SwitchBotClient.stub(:new, fake_client) do
        SensorsBroadcaster.stub(:refresh, -> { called = true }) do
          SensorPollJob.perform_now
        end
      end
    end
    assert called, "expected SensorsBroadcaster.refresh to be called"
  end

  test "enqueues the TRMNL sensor push after polling, before broadcast" do
    config = fake_config(
      switchbot: fake_sb(token: "t", secret: "s"),
      sensors: [ fake_sensor("A", :meter_pro_co2) ]
    )
    fake_client = Object.new
    def fake_client.device_status(_)
      { temperature: 1, humidity: 1, co2: 1, battery_pct: 1, firmware_version: "V", raw: {} }
    end

    order = []
    ConfigLoader.stub(:load, config) do
      SwitchBotClient.stub(:new, fake_client) do
        TrmnlSensorPushJob.stub(:perform_later, -> { order << :push }) do
          SensorsBroadcaster.stub(:refresh, -> { order << :broadcast }) do
            SensorPollJob.perform_now
          end
        end
      end
    end

    assert_equal [ :push, :broadcast ], order, "push must be enqueued before the broadcast"
  end

  test "enqueues the TRMNL sensor push even when the broadcast raises" do
    config = fake_config(
      switchbot: fake_sb(token: "t", secret: "s"),
      sensors: [ fake_sensor("A", :meter_pro_co2) ]
    )
    fake_client = Object.new
    def fake_client.device_status(_)
      { temperature: 1, humidity: 1, co2: 1, battery_pct: 1, firmware_version: "V", raw: {} }
    end

    pushed = false
    ConfigLoader.stub(:load, config) do
      SwitchBotClient.stub(:new, fake_client) do
        TrmnlSensorPushJob.stub(:perform_later, -> { pushed = true }) do
          SensorsBroadcaster.stub(:refresh, -> { raise "broadcast boom" }) do
            assert_raises(RuntimeError) { SensorPollJob.perform_now }
          end
        end
      end
    end

    assert pushed, "push should already be enqueued before the broadcast raises"
  end
end
