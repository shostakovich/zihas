class SwitchCommand < ApplicationRecord
  ACTIONS = %w[on off].freeze
  SOURCES = %w[manual schedule].freeze

  validates :plug_id, presence: true
  validates :action, inclusion: { in: ACTIONS }
  validates :source, inclusion: { in: SOURCES }

  def self.latest_for(plug_id)
    where(plug_id: plug_id).order(created_at: :desc, id: :desc).first
  end

  def self.manual_after?(plug_id, time)
    where(plug_id: plug_id, source: "manual").where("created_at > ?", time).exists?
  end
end
