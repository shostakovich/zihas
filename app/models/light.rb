class Light < ApplicationRecord
  UMLAUTS = { "ä" => "ae", "ö" => "oe", "ü" => "ue", "ß" => "ss" }.freeze

  belongs_to :room, optional: true

  validates :name, presence: true
  validates :ip_address, presence: true
  validates :key, presence: true, uniqueness: true,
                  format: { with: /\A[a-z0-9_]+\z/ }

  before_validation :assign_key, on: :create

  def to_param = key

  def self.slugify(name)
    s = name.to_s.downcase
    UMLAUTS.each { |from, to| s = s.gsub(from, to) }
    s.gsub(/[^a-z0-9]+/, "_").gsub(/\A_+|_+\z/, "")
  end

  private

  def assign_key
    return if key.present?
    base = self.class.slugify(name)
    base = "lamp" if base.empty?
    candidate = base
    counter   = 2
    while self.class.exists?(key: candidate)
      candidate = "#{base}_#{counter}"
      counter  += 1
    end
    self.key = candidate
  end
end
