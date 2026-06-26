class Light < ApplicationRecord
  belongs_to :room, optional: true

  validates :name, presence: true
  validates :key,  presence: true, uniqueness: true,
                   format: { with: /\A[0-9A-Za-z]+\z/ }

  serialize :firmware_scenes, coder: JSON, type: Array

  PLUSH_TYPES = {
    "H60B0" => "uplighter",
    "H607C" => "floorlamp",
    "H6038" => "sconce",
    "H60A6" => "ceiling"
  }.freeze

  def to_param = key

  def plush_type = PLUSH_TYPES.fetch(sku.to_s.upcase, "generic")

  # Always present, even before discovery has written a list.
  def firmware_scenes = super || []
end
