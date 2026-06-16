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
      [ 39230, 2 ] => [ 0xFFFF, 0xFF38 ]                       # battery -200 W
    })
    state = client_for(slave).read_state
    assert_equal 55, state.battery_soc
    assert_equal 300, state.active_power_w
    assert_equal 150, state.pv_power_w
    assert_equal(-200, state.battery_power_w)
  end

  # full register set so read_state_from works inside control_tick!
  def sensor_holdings(min_soc: 10)
    {
      [ 39424, 1 ] => [ 16 ],
      [ 39248, 2 ] => [ 0, 0 ],
      [ 39279, 8 ] => [ 0, 0, 0, 0, 0, 0, 0, 0 ],
      [ 39230, 2 ] => [ 0, 100 ],
      [ 46609, 1 ] => [ min_soc ]
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

  def test_release_control_disables_remote_control
    slave = FakeSlave.new
    client_for(slave).release_control!
    assert_equal [ [ :single, 46001, SolakonClient::REMOTE_CONTROL_DISABLE ] ], slave.writes
  end

  def test_errors_are_wrapped
    failing = Object.new
    def failing.read_holding_registers(*) = raise("boom")
    client = SolakonClient.new(host: "h", open: ->(&blk) { blk.call(failing) })
    assert_raises(SolakonClient::Error) { client.read_state }
  end
end
