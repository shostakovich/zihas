class Preset < ApplicationRecord
  has_many :scene_entries, dependent: :restrict_with_error
  validates :name, presence: true
end
