# Pure control policy for the Solakon One. Chooses a coarse state, then a watt
# target with simple pure functions. Battery-safety thresholds live on
# SolakonReading; control tuning lives here as constants.
class ZeroExportController
  MAX_OUTPUT_W       = 800   # legal balcony-PV feed limit
  HOT_OUTPUT_LIMIT_W = 800   # output ceiling at HOT_TEMP_C; ramps linearly to 0 at CUTOFF_TEMP_C
  NORMAL_DEADBAND_W  = 50
  DOWN_DEADBAND_W    = 15

  Decision = Struct.new(:state, :target_w, keyword_init: true) do
    # Rises must clear the normal deadband; falls use the smaller downward one so
    # the target tracks a dropping load promptly (export-safe).
    def differs_from?(previous_target_w)
      previous = previous_target_w.to_i
      return target_w - previous >= NORMAL_DEADBAND_W if target_w >= previous

      previous - target_w >= DOWN_DEADBAND_W
    end
  end

  def self.decide(reading:, load:, previous_state:)
    state = choose_state(reading: reading, previous_state: previous_state)
    raw = target_for(state, reading: reading, load: load)
    target = raw.to_f.clamp(0.0, MAX_OUTPUT_W).round

    Decision.new(state: state, target_w: target)
  end

  # Two modes only: PROTECTED (battery safety / thermal) and the normal mode,
  # which simply follows the measured household load up to the legal cap.
  def self.choose_state(reading:, previous_state:)
    protecting?(reading, previous_state) ? :protected : :normal
  end

  # Enter protection on a hard limit. Exit when BOTH SoC has resumed AND the
  # battery has cooled below HOT_TEMP_C (same threshold as entry — no hysteresis).
  def self.protecting?(reading, previous_state)
    return true if reading.soc_below_minimum? || reading.battery_hot?
    return false unless previous_state == :protected

    !(reading.soc_at_resume? && reading.battery_cooled?)
  end

  def self.target_for(state, reading:, load:)
    case state
    when :protected
      protected_target(reading, load)
    when :normal
      # Normal mode: target the measured load. The Solakon One serves it from PV
      # first and tops up from the battery internally; we don't manage that split.
      load.effective_w
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
  # Cooled below HOT_TEMP_C lifts the cap (same threshold, no hysteresis).
  def self.thermal_ceiling_w(reading)
    return MAX_OUTPUT_W if reading.battery_cooled?

    span  = SolakonReading::CUTOFF_TEMP_C - SolakonReading::HOT_TEMP_C
    ratio = (SolakonReading::CUTOFF_TEMP_C - reading.battery_temperature_c) / span
    (HOT_OUTPUT_LIMIT_W * ratio).round.clamp(0, HOT_OUTPUT_LIMIT_W)
  end
end
