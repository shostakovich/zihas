class Light < ApplicationRecord
  belongs_to :room, optional: true

  validates :name, presence: true
  validates :key,  presence: true, uniqueness: true,
                   format: { with: /\A[0-9A-Za-z]+\z/ }

  def to_param = key
end
