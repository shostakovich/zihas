require "test_helper"
require "solakon_client"

class SolakonClientTest < Minitest::Test
  class FakeSlave
    attr_reader :writes
    def initialize(holdings: {})
      @holdings = holdings
      @writes   = []
    end

    def read_holding_registers(addr, count) = @holdings.fetch([ addr, count ])
    def write_holding_register(addr, val) = (@writes << [ :single, addr, val ])
    def write_holding_registers(addr, vals) = (@writes << [ :multi, addr, vals ])
  end

  def client_for(slave)
    SolakonClient.new(host: "h", open: ->(&blk) { blk.call(slave) })
  end

  def test_read_state_decodes_signed_values_via_fc03
    slave = FakeSlave.new(holdings: {
      [ 39424, 1 ] => [ 55 ],                                   # soc 55 %
      [ 39248, 2 ] => [ 0x0000, 0x012C ],                       # active 300 W
      [ 39279, 8 ] => [ 0, 0x0064, 0, 0x0032, 0, 0, 0, 0 ],     # PV1 100W + PV2 50W (+0+0)
      [ 39230, 2 ] => [ 0xFFFF, 0xFF38 ],                      # battery -200 W
      [ 37617, 1 ] => [ 423 ]                                  # bms max temp 42.3 C
    }.merge(default_detail_holdings))
    state = client_for(slave).read_state
    assert_equal 55, state.battery_soc
    assert_equal 300, state.active_power_w
    assert_equal 150, state.pv_power_w
    assert_equal(-200, state.battery_power_w)
    assert_in_delta 42.3, state.battery_temperature_c, 0.001
  end

  # full register set so read_state_from works inside control_tick!
  def sensor_holdings(min_soc: 10)
    {
      [ 39424, 1 ] => [ 16 ],
      [ 39248, 2 ] => [ 0, 0 ],
      [ 39279, 8 ] => [ 0, 0, 0, 0, 0, 0, 0, 0 ],
      [ 39230, 2 ] => [ 0, 100 ],
      [ 37617, 1 ] => [ 200 ],
      [ 46609, 1 ] => [ min_soc ]
    }.merge(default_detail_holdings)
  end

  def default_detail_holdings
    {
      [ 39227, 1 ] => [ 512 ],
      [ 39228, 2 ] => [ 0, 0 ],
      [ 39141, 1 ] => [ 300 ],
      [ 39063, 1 ] => [ 0 ],
      [ 39065, 2 ] => [ 0, 0 ],
      [ 39067, 1 ] => [ 0 ],
      [ 39068, 1 ] => [ 0 ],
      [ 39069, 1 ] => [ 0 ],
      [ 46613, 1 ] => [ 0 ],
      [ 39201, 1 ] => [ 0 ],
      [ 39216, 2 ] => [ 0, 0 ]
    }
  end

  def test_control_tick_reads_state_then_writes_one_pass_skipping_min_soc_when_ok
    slave = FakeSlave.new(holdings: sensor_holdings(min_soc: 10))
    state = client_for(slave).control_tick!(min_soc: 10) { |_st| 300 }
    assert_equal 16, state.battery_soc
    assert_equal [
      [ :single, 46001, SolakonClient::REMOTE_CONTROL_ENABLE ],
      [ :single, 46002, SolakonClient::REMOTE_TIMEOUT_S ],
      [ :multi, 46003, [ 0x0000, 0x012C ] ]
    ], slave.writes
  end

  def test_control_tick_writes_min_soc_when_device_value_differs
    slave = FakeSlave.new(holdings: sensor_holdings(min_soc: 5))
    client_for(slave).control_tick!(min_soc: 10) { |_st| 300 }
    assert_equal [ :single, 46609, 10 ], slave.writes.first
    assert_includes slave.writes, [ :multi, 46003, [ 0x0000, 0x012C ] ]
  end

  def test_control_tick_yields_state_and_encodes_negative_power
    slave = FakeSlave.new(holdings: sensor_holdings(min_soc: 10))
    seen = nil
    client_for(slave).control_tick!(min_soc: 10) { |st| seen = st; -200 }
    assert_equal 16, seen.battery_soc
    assert_includes slave.writes, [ :multi, 46003, [ 0xFFFF, 0xFF38 ] ]
  end

  def test_apply_control_writes_remote_command_without_reading_state
    slave = FakeSlave.new(holdings: { [ 46609, 1 ] => [ 10 ] })
    client_for(slave).apply_control!(power_w: -75, min_soc: 10)
    assert_equal [
      [ :single, 46001, SolakonClient::REMOTE_CONTROL_ENABLE ],
      [ :single, 46002, SolakonClient::REMOTE_TIMEOUT_S ],
      [ :multi, 46003, [ 0xFFFF, 0xFFB5 ] ]
    ], slave.writes
  end

  def test_apply_control_writes_min_soc_when_device_value_differs
    slave = FakeSlave.new(holdings: { [ 46609, 1 ] => [ 5 ] })
    client_for(slave).apply_control!(power_w: 300, min_soc: 10)
    assert_equal [ :single, 46609, 10 ], slave.writes.first
    assert_equal [ :single, 46002, SolakonClient::REMOTE_TIMEOUT_S ], slave.writes[2]
    assert_includes slave.writes, [ :multi, 46003, [ 0x0000, 0x012C ] ]
  end

  def test_release_control_disables_remote_control
    slave = FakeSlave.new
    client_for(slave).release_control!
    assert_equal [ [ :single, 46001, SolakonClient::REMOTE_CONTROL_DISABLE ] ], slave.writes
  end

  def test_read_state_includes_fast_detail_and_eps_values
    slave = FakeSlave.new(holdings: {
      [ 39424, 1 ] => [ 55 ],
      [ 39248, 2 ] => [ 0, 300 ],
      [ 39279, 8 ] => [ 0, 100, 0, 50, 0, 0, 0, 0 ],
      [ 39230, 2 ] => [ 0xFFFF, 0xFF38 ],
      [ 37617, 1 ] => [ 423 ],
      [ 39227, 1 ] => [ 512 ],
      [ 39228, 2 ] => [ 0xFFFF, 0xF830 ],
      [ 39141, 1 ] => [ 341 ],
      [ 39063, 1 ] => [ 0b0000_0100 ],
      [ 39065, 2 ] => [ 0, 1 ],
      [ 39067, 1 ] => [ 0 ],
      [ 39068, 1 ] => [ 0b1000 ],
      [ 39069, 1 ] => [ 0 ],
      [ 46613, 1 ] => [ SolakonClient::EPS_OUTPUT_VALUES.fetch(:eps) ],
      [ 39201, 1 ] => [ 2301 ],
      [ 39216, 2 ] => [ 0, 125 ]
    })

    state = client_for(slave).read_state

    assert_in_delta 51.2, state.battery_voltage_v, 0.001
    assert_in_delta(-2.0, state.battery_current_a, 0.001)
    assert_in_delta 34.1, state.inverter_temperature_c, 0.001
    assert_equal 0b0000_0100, state.status1
    assert_equal 1, state.status3
    assert_equal 0b1000, state.alarm2
    assert_equal true, state.eps_enabled
    assert_in_delta 230.1, state.eps_voltage_v, 0.001
    assert_equal 125, state.eps_power_w
  end

  def test_set_eps_output_writes_directly_to_solakon_register
    slave = FakeSlave.new

    client_for(slave).set_eps_output!(enabled: true)
    client_for(slave).set_eps_output!(enabled: false)

    assert_equal [
      [ :single, SolakonClient::WRITE_REGISTERS.fetch(:eps_output), SolakonClient::EPS_OUTPUT_VALUES.fetch(:eps) ],
      [ :single, SolakonClient::WRITE_REGISTERS.fetch(:eps_output), SolakonClient::EPS_OUTPUT_VALUES.fetch(:off) ]
    ], slave.writes
  end

  def test_status_messages_are_human_readable
    messages = SolakonClient.decode_status_messages(
      status1: 0b0100,
      status3: 0,
      alarm1: 0,
      alarm2: 0b1000,
      alarm3: 0,
      bms_faults: [ 0, 0, 0, 0, 0, 0 ]
    )

    assert_includes messages, "Wechselrichter in Betrieb"
    assert_includes messages, "Temperatur zu hoch"
    assert messages.none? { |message| message.match?(/390|Alarm 2|Bit/) }
  end

  def test_read_snapshot_decodes_panel_storage_energy_and_status_values
    slave = FakeSlave.new(holdings: default_detail_holdings.merge({
      [ 39424, 1 ] => [ 16 ],
      [ 39248, 2 ] => [ 0, 0 ],
      [ 39230, 2 ] => [ 0, 0 ],
      [ 39070, 8 ] => [ 410, 512, 405, 488, 0, 0, 0, 0 ],
      [ 39279, 8 ] => [ 0, 210, 0, 198, 0, 0, 0, 0 ],
      [ 37609, 1 ] => [ 513 ],
      [ 37610, 1 ] => [ 42 ],
      [ 37611, 1 ] => [ 248 ],
      [ 37617, 1 ] => [ 423 ],
      [ 37618, 1 ] => [ 211 ],
      [ 37624, 1 ] => [ 97 ],
      [ 37626, 6 ] => [ 0, 0, 0, 0, 0, 0 ],
      [ 37632, 1 ] => [ 1234 ],
      [ 37633, 1 ] => [ 512 ],
      [ 37635, 1 ] => [ 19200 ],
      [ 39141, 1 ] => [ 341 ],
      [ 39168, 2 ] => [ 0xFFFF, 0xFF9C ],
      [ 39216, 2 ] => [ 0, 125 ],
      [ 39601, 20 ] => [ 0, 12345, 0, 345, 0, 6789, 0, 120, 0, 4567, 0, 98, 0, 2222, 0, 55, 0, 3333, 0, 77 ]
    }))

    snapshot = client_for(slave).read_snapshot

    assert_equal 4, snapshot.panels.length
    assert_in_delta 41.0, snapshot.panels[0].voltage_v, 0.001
    assert_in_delta 5.12, snapshot.panels[0].current_a, 0.001
    assert_equal 210, snapshot.panels[0].power_w
    assert_in_delta 51.3, snapshot.battery_voltage_v, 0.001
    assert_in_delta 4.2, snapshot.battery_current_a, 0.001
    assert_equal 97, snapshot.battery_health_pct
    assert_in_delta 123.4, snapshot.remaining_energy_wh, 0.001
    assert_in_delta 51.2, snapshot.full_charge_capacity_ah, 0.001
    assert_in_delta 1920.0, snapshot.design_energy_wh, 0.001
    assert_equal 100, snapshot.grid_power_w
    assert_in_delta 123.45, snapshot.pv_total_kwh, 0.001
    assert_in_delta 67.89, snapshot.battery_charge_total_kwh, 0.001
    assert_in_delta 45.67, snapshot.battery_discharge_total_kwh, 0.001
    assert_in_delta 22.22, snapshot.grid_export_total_kwh, 0.001
    assert_in_delta 33.33, snapshot.grid_import_total_kwh, 0.001
  end

  def test_errors_are_wrapped
    failing = Object.new
    def failing.read_holding_registers(*) = raise("boom")
    client = SolakonClient.new(host: "h", open: ->(&blk) { blk.call(failing) })
    assert_raises(SolakonClient::Error) { client.read_state }
  end
end
