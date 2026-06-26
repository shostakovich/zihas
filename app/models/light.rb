class Light < ApplicationRecord
  belongs_to :room, optional: true

  validates :name, presence: true
  validates :key,  presence: true, uniqueness: true,
                   format: { with: /\A[0-9A-Za-z]+\z/ }

  serialize :firmware_scenes, coder: JSON, type: Array

  def to_param = key

  # Always present, even before discovery has written a list.
  def firmware_scenes = super || []
end
