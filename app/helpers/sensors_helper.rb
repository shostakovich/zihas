# app/helpers/sensors_helper.rb
module SensorsHelper
  CO2_WARN_PPM    = 1000
  CO2_BAD_PPM     = 1400
  BATTERY_LOW_PCT = 20

  def co2_level(ppm)
    return nil if ppm.nil?
    return :bad  if ppm > CO2_BAD_PPM
    return :warn if ppm >= CO2_WARN_PPM
    :good
  end

  def co2_icon_path(level)
    "co2_#{level}.png"
  end

  def battery_low?(pct)
    return false if pct.nil?
    pct <= BATTERY_LOW_PCT
  end

  def relative_time(time)
    return "—" if time.nil?
    delta = (Time.current - time).to_i
    return "vor #{delta} s"   if delta < 60
    return "vor #{delta / 60} Min" if delta < 3600
    "vor #{delta / 3600} h"
  end
end
