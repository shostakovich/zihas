# Pure control policy for the Solakon One. Chooses a coarse state, then a watt
# target with simple pure functions. Battery-safety thresholds live on
# SolakonReading; control tuning lives here as constants.
class ZeroExportController
  MAX_OUTPUT_W             = 800   # legal balcony-PV feed limit
  DAY_BATTERY_HELP_W       = 250   # max daytime battery assist
  EVENING_DISCHARGE_LIMIT_W = 800
  HOT_OUTPUT_LIMIT_W       = 400   # output ceiling at HOT_TEMP_C; ramps linearly to 0 at CUTOFF_TEMP_C
  NORMAL_DEADBAND_W        = 50
  BASE_DEADBAND_W          = 15
  NIGHT_BASE_RESERVE_W     = 5
  RISE_FACTOR              = 0.25  # slow up: take 25% of the gap...
  RISE_CAP_W               = 50    # ...but at most 50W per tick
  FALL_FACTOR              = 0.80  # fast down

  Decision = Struct.new(:state, :target_w, :deadband_w, :smoothed_load_w, keyword_init: true) do
    def differs_from?(previous_target_w)
      (target_w - previous_target_w.to_i).abs >= deadband_w
    end
  end

  def self.decide(reading:, load:, sun:, previous_state:, smoothed_load_w:)
    state = choose_state(reading: reading, sun: sun, load: load, previous_state: previous_state)
    raw, evening_smoothed = target_for(state, reading: reading, load: load, smoothed_load_w: smoothed_load_w)
    target = raw.to_f.clamp(0.0, MAX_OUTPUT_W).round

    Decision.new(
      state: state,
      target_w: target,
      deadband_w: state == :night_base ? BASE_DEADBAND_W : NORMAL_DEADBAND_W,
      # Carry the real output forward across all states so the first
      # evening_catch_up tick ramps up from the last setpoint instead of
      # re-seeding to the current load (which would bypass the slow-up cap).
      smoothed_load_w: state == :evening_catch_up ? evening_smoothed : target.to_f
    )
  end

  def self.choose_state(reading:, sun:, load:, previous_state:)
    return :protected if protecting?(reading, previous_state)
    return :pv_priority if sun.daytime? || reading.pv_present?

    enough_for_morning?(reading, sun, load) ? :night_base : :evening_catch_up
  end

  # Enter protection on a hard limit; once in it, stay until BOTH the SoC has
  # resumed and the battery has cooled (hysteresis around the entry thresholds).
  def self.protecting?(reading, previous_state)
    return true if reading.soc_below_minimum? || reading.battery_hot?
    return false unless previous_state == :protected

    !(reading.soc_at_resume? && reading.battery_cooled?)
  end

  def self.enough_for_morning?(reading, sun, load)
    reading.usable_wh <= load.night_base_w * sun.hours_until_sunrise
  end

  def self.target_for(state, reading:, load:, smoothed_load_w:)
    case state
    when :protected
      [ protected_target(reading, load), nil ]
    when :pv_priority
      [ pv_priority_target(reading, load), nil ]
    when :evening_catch_up
      # Cold start (no carried setpoint) seeds from base load, not the current
      # load, so even a first-ever tick ramps up rather than jumping.
      smoothed = rise_slow_fall_fast(load.effective_w, smoothed_load_w || load.night_base_w)
      [ [ smoothed, load.effective_w, EVENING_DISCHARGE_LIMIT_W ].min, smoothed ]
    when :night_base
      [ [ load.night_base_w - NIGHT_BASE_RESERVE_W, load.effective_w ].min, nil ]
    end
  end

  # Below resume SoC: no intentional discharge (PV only). Above it: normal PV
  # priority. While the battery is warm, throttle the *whole* AC output to the
  # thermal ceiling — but always follow the (lower) load, since less throughput
  # means less inverter heat.
  def self.protected_target(reading, load)
    base = reading.soc_at_resume? ? load.effective_w : [ reading.pv_power_w, load.effective_w ].min
    [ base, thermal_ceiling_w(reading) ].min
  end

  # Linear thermal de-rating, independent of SoC: at HOT_TEMP_C the ceiling is
  # the full HOT_OUTPUT_LIMIT_W, ramping straight down to 0 at CUTOFF_TEMP_C
  # (above which the battery must not discharge). A full, hot battery is throttled
  # too — the inverter simply curtails PV when there is nowhere for it to go.
  # Cooled below the resume threshold lifts the cap entirely (hysteresis).
  def self.thermal_ceiling_w(reading)
    return MAX_OUTPUT_W if reading.battery_cooled?

    span  = SolakonReading::CUTOFF_TEMP_C - SolakonReading::HOT_TEMP_C
    ratio = (SolakonReading::CUTOFF_TEMP_C - reading.battery_temperature_c) / span
    (HOT_OUTPUT_LIMIT_W * ratio).round.clamp(0, HOT_OUTPUT_LIMIT_W)
  end

  def self.pv_priority_target(reading, load)
    pv_direct = [ reading.pv_power_w, load.effective_w ].min
    remaining = [ load.effective_w - pv_direct, 0.0 ].max
    pv_direct + [ remaining, DAY_BATTERY_HELP_W ].min
  end

  def self.rise_slow_fall_fast(load_w, previous_w)
    step = load_w - previous_w
    return previous_w + [ step * RISE_FACTOR, RISE_CAP_W ].min if step.positive?

    previous_w + step * FALL_FACTOR
  end
end
