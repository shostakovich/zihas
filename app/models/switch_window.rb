class SwitchWindow < ApplicationRecord
  ISO_DAYS = (1..7).to_a.freeze
  MINUTE_RANGE = (0..1439)

  before_validation :normalize_days

  validates :plug_id, presence: true
  validates :on_at,  inclusion: { in: MINUTE_RANGE, message: "muss zwischen 00:00 und 23:59 liegen" }
  validates :off_at, inclusion: { in: MINUTE_RANGE, message: "muss zwischen 00:00 und 23:59 liegen" }
  validate  :on_and_off_differ
  validate  :days_are_iso_weekdays

  scope :enabled, -> { where(enabled: true) }

  def crosses_midnight?
    on_at > off_at
  end

  def on_at_time  = format_minutes(on_at)
  def off_at_time = format_minutes(off_at)

  def on_at_time=(str)
    self.on_at = parse_minutes(str)
  end

  def off_at_time=(str)
    self.off_at = parse_minutes(str)
  end

  private

  def format_minutes(minutes)
    return nil if minutes.nil?
    format("%02d:%02d", minutes / 60, minutes % 60)
  end

  def parse_minutes(str)
    return nil unless str.to_s =~ /\A([01]?\d|2[0-3]):([0-5]\d)(?::[0-5]\d)?\z/
    Integer($1) * 60 + Integer($2)
  end

  def normalize_days
    return unless days.is_a?(Array)
    self.days = days.reject { |d| d.to_s.strip.empty? }.map(&:to_i).uniq.sort
  end

  def on_and_off_differ
    return if on_at.nil? || off_at.nil?
    errors.add(:off_at, "muss sich von der Startzeit unterscheiden") if on_at == off_at
  end

  def days_are_iso_weekdays
    unless days.is_a?(Array) && days.any? && days.all? { |d| ISO_DAYS.include?(d) }
      errors.add(:days, "mindestens ein Wochentag muss gewählt sein")
    end
  end
end
