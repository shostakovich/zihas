require "json"

module Govees
  # Schlüsselquelle + Anonymisierung für VCR-Cassettes: liefert den echten
  # API-Key beim Aufnehmen (aus der gitignored config/ziwoas.yml) und ersetzt
  # MAC-Adressen sowie Gerätenamen, bevor eine Interaktion auf Platte landet.
  module CassetteScrubber
    # Govee-Geräte-IDs sind MACs variabler Oktett-Länge (häufig 8, nicht 6) —
    # daher `+` statt fester Wiederholung, sonst leaken die letzten Oktette.
    MAC               = /\b[0-9A-Fa-f]{2}(?::[0-9A-Fa-f]{2})+\b/     # AA:BB:CC:DD:EE:FF(:..)*
    KEY16             = /\b[0-9A-F]{16}\b/                           # MAC ohne Doppelpunkte, upcase
    PLACEHOLDER_MAC   = "AA:BB:CC:DD:EE:FF".freeze
    PLACEHOLDER_KEY16 = "0000000000000000".freeze

    def self.api_key
      path = Rails.root.join("config", "ziwoas.yml")
      return ConfigLoader.app_config.govee&.api_key.to_s unless File.exist?(path)
      ConfigLoader.load(path.to_s).govee&.api_key.to_s
    rescue StandardError
      ConfigLoader.app_config.govee&.api_key.to_s
    end

    def self.scrub!(interaction)
      [ interaction.request, interaction.response ].each do |msg|
        next unless msg&.body
        body = msg.body.gsub(MAC, PLACEHOLDER_MAC).gsub(KEY16, PLACEHOLDER_KEY16)
        msg.body = scrub_names(body)
      end
    end

    def self.scrub_names(body)
      JSON.generate(deep_scrub_names(JSON.parse(body)))
    rescue JSON::ParserError
      body
    end

    # Anonymisiere Geräte-IDs/-Namen anhand des JSON-Keys — fängt jede ID-Form
    # (auch colon-freie Hex-IDs), unabhängig von den Regex oben.
    def self.deep_scrub_names(node)
      case node
      when Hash then node.to_h { |k, v| [ k, scrub_value(k, v) ] }
      when Array then node.map { |v| deep_scrub_names(v) }
      else node
      end
    end

    def self.scrub_value(key, value)
      case key
      when "deviceName" then "Lampe"
      when "device"     then PLACEHOLDER_MAC
      else deep_scrub_names(value)
      end
    end
  end
end
