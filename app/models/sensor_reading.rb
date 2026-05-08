class SensorReading < ApplicationRecord
  OUTDOOR_FRESHNESS = 30.minutes

  scope :for_device, ->(id) { where(device_id: id) }
  scope :since,      ->(t)  { where("taken_at >= ?", t) }

  def self.fresh_outdoor(device_ids, within: OUTDOOR_FRESHNESS)
    return nil if device_ids.blank?
    where(device_id: device_ids)
      .where("taken_at >= ?", within.ago)
      .order(taken_at: :desc)
      .first
  end

  def self.latest_per_device(device_ids)
    return none if device_ids.blank?
    where(device_id: device_ids)
      .where("taken_at = (SELECT MAX(taken_at) FROM sensor_readings sr2
                          WHERE sr2.device_id = sensor_readings.device_id)")
  end
end
