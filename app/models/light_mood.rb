# Curated "Stimmungen" for the lamp detail page's Szenen tab. Each mood is a
# colour/temperature/brightness recipe that works on any lamp (composed from the
# same primitives as GoveeCommander). Pure value object — no persistence.
class LightMood
  Mood = Data.define(:id, :name, :emoji, :gradient, :brightness, :color, :color_temp_k)

  ALL = [
    Mood.new(id: "sunset", name: "Sonnenuntergang", emoji: "🌅",
             gradient: "linear-gradient(135deg, #ffb24d, #ff7a3d)",
             brightness: 60, color: { r: 255, g: 122, b: 61 }, color_temp_k: nil),
    Mood.new(id: "reading", name: "Lesen", emoji: "📖",
             gradient: "linear-gradient(135deg, #fff4e0, #ffd9a0)",
             brightness: 80, color: nil, color_temp_k: 3000),
    Mood.new(id: "cinema", name: "Kino", emoji: "🎬",
             gradient: "linear-gradient(135deg, #1a1a2e, #4d3a8c)",
             brightness: 15, color: { r: 77, g: 58, b: 140 }, color_temp_k: nil),
    Mood.new(id: "party", name: "Party", emoji: "🎉",
             gradient: "linear-gradient(135deg, #ff4d6d, #7c5cff, #22b8cf)",
             brightness: 100, color: { r: 255, g: 77, b: 109 }, color_temp_k: nil)
  ].freeze

  def self.find(id) = ALL.find { |m| m.id == id }
end
