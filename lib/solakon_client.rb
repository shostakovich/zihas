require "rmodbus"

# Thin Modbus-TCP wrapper for the Solakon One inverter.
#
# Register addresses, function codes and the bitfield encoding are taken from
# the official "Solakon ONE Modbus Protokoll" (02/26) and verified live against
# the device: ALL registers are read/written as *holding* registers (FC03/FC06/
# FC16); 32-bit values are big-endian (high word first).
class SolakonClient
  class Error < StandardError; end

  # --- Control registers (RW, volatile — safe to write every tick) ---
  REG_REMOTE_CONTROL      = 46001 # Bitfield16 – see REMOTE_CONTROL_ENABLE
  REG_REMOTE_TIMEOUT      = 46002 # u16  – seconds; inverter reverts if no command within this window
  REG_REMOTE_ACTIVE_POWER = 46003 # i32  – active-power setpoint (W, 2 regs)

  # --- Config register (RW, persisted — do NOT write every tick) ---
  REG_MINIMUM_SOC = 46609 # u16 – % [10,100]

  # --- Sensor registers (RO) ---
  REG_BATTERY_SOC    = 39424 # i16 – %
  REG_ACTIVE_POWER   = 39248 # i32 – INV active power (W, 2 regs)
  REG_BATTERY_POWER  = 39230 # i32 – battery power (W, 2 regs)
  # Per-string PV power is contiguous (PVn = 39279 + 2·(n−1), i32 W each);
  # there is no instantaneous total-PV register, so we sum the first strings.
  # Unused strings read 0, so reading a few extra is harmless.
  REG_PV_POWER_BASE = 39279
  PV_STRINGS        = 4

  # 46001 bitfield: bit0=enable, bit1=direction (0=generation), bits3:2=target
  # (00=AC). 0b0001 = remote control on, generation onto AC. (Doc: "00 0 1".)
  REMOTE_CONTROL_ENABLE  = 0b0001
  REMOTE_CONTROL_DISABLE = 0

  # Inverter-side watchdog: if no remote command arrives within this many
  # seconds, the inverter drops remote control and reverts to its default.
  # Larger than the 60s tick so normal operation never trips it.
  REMOTE_TIMEOUT_S = 150

  State = Struct.new(:battery_soc, :active_power_w, :pv_power_w, :battery_power_w,
                     keyword_init: true)

  def initialize(host:, port: 502, unit_id: 1, open: nil)
    @host    = host
    @port    = port
    @unit_id = unit_id
    @open    = open || method(:default_open)
  end

  def read_state
    with_slave { |slave| read_state_from(slave) }
  end

  # A full control cycle over a SINGLE Modbus connection: read inverter state,
  # let the caller decide the setpoint from it (the yielded block returns the
  # desired watts), then write the control command. Returns the State that was
  # read. Doing read+write on one connection halves connection churn, which
  # matters at higher tick rates (e.g. every 30s).
  def control_tick!(min_soc:)
    with_slave do |slave|
      state   = read_state_from(slave)
      power_w = yield(state)
      write_control!(slave, power_w: power_w, min_soc: min_soc)
      state
    end
  end

  # Relinquish remote control so the inverter reverts to its safe default.
  def release_control!
    with_slave { |slave| slave.write_holding_register(REG_REMOTE_CONTROL, REMOTE_CONTROL_DISABLE) }
  end

  private

  def read_state_from(slave)
    pv_regs = slave.read_holding_registers(REG_PV_POWER_BASE, PV_STRINGS * 2)
    pv_w    = (0...PV_STRINGS).sum { |n| to_i32(pv_regs[n * 2, 2]) }
    State.new(
      battery_soc:     to_i16(slave.read_holding_registers(REG_BATTERY_SOC, 1).first),
      active_power_w:  to_i32(slave.read_holding_registers(REG_ACTIVE_POWER, 2)),
      pv_power_w:      pv_w,
      battery_power_w: to_i32(slave.read_holding_registers(REG_BATTERY_POWER, 2)),
    )
  end

  # Ensure the minimum-SoC guard, enable remote control, (re)arm the inverter
  # watchdog, then write the active-power setpoint last. min_soc is written only
  # when it differs from the desired value, so the loop self-heals a reset/
  # out-of-band device without wearing flash on every tick.
  def write_control!(slave, power_w:, min_soc:)
    desired_soc = min_soc.to_i
    if slave.read_holding_registers(REG_MINIMUM_SOC, 1).first != desired_soc
      slave.write_holding_register(REG_MINIMUM_SOC, desired_soc)
    end
    slave.write_holding_register(REG_REMOTE_CONTROL, REMOTE_CONTROL_ENABLE)
    slave.write_holding_register(REG_REMOTE_TIMEOUT, REMOTE_TIMEOUT_S)
    slave.write_holding_registers(REG_REMOTE_ACTIVE_POWER, from_i32(power_w.to_i))
  end

  def default_open(&blk)
    # ModBus::TCPClient.connect returns the client, not the block's value, so
    # capture the result explicitly and return it.
    result = nil
    ModBus::TCPClient.connect(@host, @port) do |client|
      client.with_slave(@unit_id) { |slave| result = blk.call(slave) }
    end
    result
  end

  def with_slave(&blk)
    @open.call(&blk)
  rescue Error
    raise
  rescue StandardError => e
    raise Error, "#{e.class}: #{e.message}"
  end

  # Big-endian word order: [high, low]
  def to_i32(regs)
    raw = ((regs[0] & 0xFFFF) << 16) | (regs[1] & 0xFFFF)
    raw >= 0x8000_0000 ? raw - 0x1_0000_0000 : raw
  end

  def from_i32(value)
    raw = value.negative? ? value + 0x1_0000_0000 : value
    [ (raw >> 16) & 0xFFFF, raw & 0xFFFF ]
  end

  def to_i16(reg)
    reg >= 0x8000 ? reg - 0x1_0000 : reg
  end
end
