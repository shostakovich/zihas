class Light < ApplicationRecord
  validates :name, presence: true
  validates :key,  presence: true, uniqueness: true,
                   format: { with: /\A[0-9A-Za-z]+\z/ }

  serialize :firmware_scenes, coder: JSON, type: Array
  serialize :zones, coder: JSON, type: Array

  # Toggle instance key → display label + role. Single source of zone copy;
  # `lights.zones` stores only the keys. Only listed instances count as zones
  # (powerSwitch / dreamViewToggle / gradientToggle are control toggles, not zones).
  ZONE_META = {
    "bottomLightToggle" => { label: "Leselicht", role: "main" },
    "rippleLightToggle" => { label: "Welle",     role: "side" },
    "sideLightToggle"   => { label: "Seite",     role: "side" },
    "baseLightToggle"   => { label: "Sockel",    role: "main" },
    "pillarLightToggle" => { label: "Säule",     role: "side" },
    "leftLightToggle"   => { label: "Links",     role: "side" },
    "rightLightToggle"  => { label: "Rechts",    role: "side" }
  }.freeze

  # Hardware limit: at most N zones lit at once (Uplighter). nil = no limit.
  MAX_ACTIVE_ZONES = { "H60B0" => 2 }.freeze

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

  def zones = super || []
  def zone_lamp? = zones.size >= 2
  def max_active_zones = MAX_ACTIVE_ZONES[sku.to_s.upcase]
end
