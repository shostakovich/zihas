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
  REG_BMS_MAX_TEMP  = 37617 # i16, scale 10, Celsius

  WRITE_REGISTERS = {
    eps_output: 46613
  }.freeze

  EPS_OUTPUT_VALUES = {
    off: 0,
    eps: 2
  }.freeze

  FAST_FIELD_SPECS = {
    battery_soc: { addr: 39424, type: :i16 },
    active_power_w: { addr: 39248, count: 2, type: :i32 },
    battery_power_w: { addr: 39230, count: 2, type: :i32 },
    battery_temperature_c: { addr: 37617, type: :i16, scale: 10.0 },
    battery_voltage_v: { addr: 39227, type: :i16, scale: 10.0 },
    battery_current_a: { addr: 39228, count: 2, type: :i32, scale: 1000.0 },
    inverter_temperature_c: { addr: 39141, type: :i16, scale: 10.0 },
    status1: { addr: 39063, type: :u16 },
    status3: { addr: 39065, count: 2, type: :u32 },
    alarm1: { addr: 39067, type: :u16 },
    alarm2: { addr: 39068, type: :u16 },
    alarm3: { addr: 39069, type: :u16 },
    eps_mode: { addr: 46613, type: :u16 },
    eps_voltage_v: { addr: 39201, type: :u16, scale: 10.0 },
    eps_power_w: { addr: 39216, count: 2, type: :i32 }
  }.freeze

  FIELD_SPECS = {
    fast: FAST_FIELD_SPECS,
    snapshot: FAST_FIELD_SPECS.merge(
      battery_voltage_v: { addr: 37609, type: :u16, scale: 10.0 },
      battery_current_a: { addr: 37610, type: :i16, scale: 10.0 },
      battery_temperature_c: { addr: 37611, type: :i16, scale: 10.0 },
      battery_min_temperature_c: { addr: 37618, type: :i16, scale: 10.0 },
      battery_health_pct: { addr: 37624, type: :u16 },
      remaining_energy_wh: { addr: 37632, type: :u16, scale: 10.0 },
      full_charge_capacity_ah: { addr: 37633, type: :u16, scale: 10.0 },
      design_energy_wh: { addr: 37635, type: :u16, scale: 10.0 },
      grid_power_w: { addr: 39168, count: 2, type: :i32, map: ->(value) { -value } }
    )
  }.freeze

  GROUPED_READ_SPECS = {
    pv_power: { addr: 39279, count: -> { PV_STRINGS * 2 } },
    pv_voltage_current: { addr: 39070, count: -> { PV_STRINGS * 2 } },
    bms_faults: { addr: 37626, count: 6 },
    energy_counters: { addr: 39601, count: 20 }
  }.freeze

  # 46001 bitfield: bit0=enable, bit1=direction (0=generation), bits3:2=target
  # (00=AC). 0b0001 = remote control on, generation onto AC. (Doc: "00 0 1".)
  REMOTE_CONTROL_ENABLE  = 0b0001
  REMOTE_CONTROL_DISABLE = 0

  # Inverter-side watchdog: if no remote command arrives within this many
  # seconds, the inverter drops remote control and reverts to its default.
  # Larger than the 60s tick so normal operation never trips it.
  REMOTE_TIMEOUT_S = 150

  State = Struct.new(:battery_soc, :active_power_w, :pv_power_w, :battery_power_w,
                     :battery_temperature_c, :battery_voltage_v, :battery_current_a,
                     :inverter_temperature_c, :status1, :status3, :alarm1, :alarm2,
                     :alarm3, :eps_enabled, :eps_voltage_v, :eps_power_w,
                     keyword_init: true)

  PanelData = Struct.new(:index, :voltage_v, :current_a, :power_w, keyword_init: true)
  SnapshotData = Struct.new(
    :panels, :battery_voltage_v, :battery_current_a, :battery_temperature_c,
    :battery_min_temperature_c, :battery_health_pct, :remaining_energy_wh,
    :full_charge_capacity_ah, :design_energy_wh, :inverter_temperature_c,
    :grid_power_w, :eps_enabled, :eps_voltage_v, :eps_power_w,
    :status1, :status3, :alarm1, :alarm2, :alarm3, :bms_faults,
    :pv_total_kwh, :battery_charge_total_kwh, :battery_discharge_total_kwh,
    :grid_export_total_kwh, :grid_import_total_kwh,
    keyword_init: true
  )

  def self.decode_status_messages(status1:, status3:, alarm1:, alarm2:, alarm3:, bms_faults: [])
    messages = []
    messages << "Wechselrichter bereit" if (status1.to_i & 0b0001).positive?
    messages << "Wechselrichter in Betrieb" if (status1.to_i & 0b0100).positive?
    messages << "Wechselrichter meldet Fehler" if (status1.to_i & 0b0100_0000).positive?
    messages << "Inselbetrieb aktiv" if (status3.to_i & 0b0001).positive?

    alarm_map = {
      alarm1: {
        0 => "PV-Spannung zu hoch",
        1 => "DC-Lichtbogenfehler",
        2 => "PV-String verpolt",
        8 => "Netzausfall",
        9 => "Netzspannung auffällig",
        11 => "Netzfrequenz auffällig",
        14 => "Ausgangsstrom zu hoch",
        15 => "DC-Anteil im Ausgangsstrom zu groß"
      },
      alarm2: {
        0 => "Fehlerstrom auffällig",
        1 => "Erdung auffällig",
        2 => "Isolationswiderstand zu niedrig",
        3 => "Temperatur zu hoch",
        9 => "Energiespeicher auffällig",
        10 => "Inselbetrieb erkannt",
        14 => "Außensteckdose überlastet"
      },
      alarm3: {
        3 => "Lüfter auffällig",
        4 => "Energiespeicher verpolt",
        9 => "Zählerverbindung verloren",
        10 => "Batteriemanagement nicht erreichbar"
      }
    }

    { alarm1: alarm1.to_i, alarm2: alarm2.to_i, alarm3: alarm3.to_i }.each do |key, value|
      alarm_map.fetch(key).each do |bit, label|
        messages << label if (value & (1 << bit)).positive?
      end
    end

    messages << "Batterie-Warnung" if bms_faults.any? { |fault| fault.to_i.positive? }
    messages.presence || [ "Alles ruhig" ]
  end

  def initialize(host:, port: 502, unit_id: 1, open: nil)
    @host    = host
    @port    = port
    @unit_id = unit_id
    @open    = open || method(:default_open)
  end

  def read_state
    with_slave { |slave| read_state_from(slave) }
  end

  def read_snapshot
    with_slave { |slave| read_snapshot_from(slave) }
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

  def apply_control!(power_w:, min_soc:)
    with_slave do |slave|
      write_control!(slave, power_w: power_w.to_i, min_soc: min_soc)
    end
  rescue StandardError => e
    raise Error, e.message
  end

  def set_eps_output!(enabled:)
    value = enabled ? EPS_OUTPUT_VALUES.fetch(:eps) : EPS_OUTPUT_VALUES.fetch(:off)
    with_slave { |slave| slave.write_holding_register(WRITE_REGISTERS.fetch(:eps_output), value) }
  rescue StandardError => e
    raise Error, e.message
  end

  # Relinquish remote control so the inverter reverts to its safe default.
  def release_control!
    with_slave { |slave| slave.write_holding_register(REG_REMOTE_CONTROL, REMOTE_CONTROL_DISABLE) }
  end

  private

  def read_state_from(slave)
    fields = read_fields(slave, :fast)

    State.new(
      **fields.slice(:battery_soc, :active_power_w, :battery_power_w,
                     :battery_temperature_c, :battery_voltage_v, :battery_current_a,
                     :inverter_temperature_c, :status1, :status3, :alarm1, :alarm2,
                     :alarm3, :eps_voltage_v, :eps_power_w),
      pv_power_w: read_pv_power_w(slave),
      eps_enabled: fields.fetch(:eps_mode) == EPS_OUTPUT_VALUES.fetch(:eps)
    )
  end

  def read_snapshot_from(slave)
    fields = read_fields(slave, :snapshot)
    groups = read_snapshot_groups(slave)
    energy = decode_energy_counters(groups.fetch(:energy_counters))

    SnapshotData.new(
      **fields.slice(:battery_voltage_v, :battery_current_a, :battery_temperature_c,
                     :battery_min_temperature_c, :battery_health_pct, :remaining_energy_wh,
                     :full_charge_capacity_ah, :design_energy_wh, :inverter_temperature_c,
                     :grid_power_w, :eps_voltage_v, :eps_power_w,
                     :status1, :status3, :alarm1, :alarm2, :alarm3),
      panels: read_panels(groups),
      eps_enabled: fields.fetch(:eps_mode) == EPS_OUTPUT_VALUES.fetch(:eps),
      bms_faults: groups.fetch(:bms_faults),
      **energy
    )
  end

  def read_snapshot_groups(slave)
    %i[pv_voltage_current pv_power bms_faults energy_counters].to_h do |key|
      [ key, read_register_group(slave, key) ]
    end
  end

  def read_panels(groups)
    vi = groups.fetch(:pv_voltage_current)
    powers = groups.fetch(:pv_power)

    (0...PV_STRINGS).map do |idx|
      PanelData.new(
        index: idx + 1,
        voltage_v: scaled(decode_register_value([ vi[idx * 2] ], :i16), 10),
        current_a: scaled(decode_register_value([ vi[idx * 2 + 1] ], :i16), 100),
        power_w: decode_register_value(powers[idx * 2, 2], :i32)
      )
    end
  end

  def decode_energy_counters(regs)
    {
      pv_total_kwh: energy_counter_kwh(regs[0, 2]),
      battery_charge_total_kwh: energy_counter_kwh(regs[4, 2]),
      battery_discharge_total_kwh: energy_counter_kwh(regs[8, 2]),
      grid_export_total_kwh: energy_counter_kwh(regs[12, 2]),
      grid_import_total_kwh: energy_counter_kwh(regs[16, 2])
    }
  end

  def energy_counter_kwh(regs)
    scaled(decode_register_value(regs, :u32), 100)
  end

  def scaled(value, divisor)
    value.to_f / divisor
  end

  def read_fields(slave, group)
    FIELD_SPECS.fetch(group).transform_values { |spec| read_field(slave, spec) }
  end

  def read_field(slave, spec)
    regs = slave.read_holding_registers(spec.fetch(:addr), spec.fetch(:count, 1))
    value = decode_register_value(regs, spec.fetch(:type))
    scale = spec.fetch(:scale, 1.0)
    value = value / scale if scale != 1.0
    spec[:map] ? spec.fetch(:map).call(value) : value
  end

  def read_pv_power_w(slave)
    regs = read_register_group(slave, :pv_power)
    (0...PV_STRINGS).sum { |idx| decode_register_value(regs[idx * 2, 2], :i32) }
  end

  def read_register_group(slave, key)
    spec = GROUPED_READ_SPECS.fetch(key)
    count = spec.fetch(:count)
    slave.read_holding_registers(spec.fetch(:addr), count.respond_to?(:call) ? count.call : count)
  end

  def decode_register_value(regs, type)
    case type
    when :u16 then regs.first.to_i
    when :i16 then to_i16(regs.first)
    when :u32 then to_u32(regs)
    when :i32 then to_i32(regs)
    else raise Error, "unknown register type: #{type}"
    end
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

  def to_u32(regs)
    ((regs[0] & 0xFFFF) << 16) | (regs[1] & 0xFFFF)
  end

  # Big-endian word order: [high, low]
  def to_i32(regs)
    raw = to_u32(regs)
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
