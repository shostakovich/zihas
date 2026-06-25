class Room < ApplicationRecord
  has_many :lights, dependent: :nullify
  validates :name, presence: true, uniqueness: true
end
