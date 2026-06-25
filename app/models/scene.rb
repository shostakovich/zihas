class Scene < ApplicationRecord
  has_many :scene_entries, dependent: :destroy
  validates :name, presence: true
end
