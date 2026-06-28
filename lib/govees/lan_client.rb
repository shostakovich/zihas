# lib/govees/lan_client.rb
require "json"
require "socket"
require "dry/struct"
require "govees/types"

module Govees
  # Pure Govee LAN protocol: serialize commands, send UDP to :4003, parse
  # devStatus + scan replies. No MQTT, no DB. Socket factory is injectable.
  class LanClient
    CMD_PORT   = 4003
    SCAN_MCAST = "239.255.255.250"
    SCAN_PORT  = 4001
    LISTEN_PORT = 4002

    # Parsed LAN devStatus reading. Fields a device omits arrive as nil.
    class Status < Dry::Struct
      attribute  :on,           Types::Bool
      attribute? :brightness,   Types::Brightness.optional
      attribute? :color_r,      Types::RgbComponent.optional
      attribute? :color_g,      Types::RgbComponent.optional
      attribute? :color_b,      Types::RgbComponent.optional
      attribute? :color_temp_k, Types::Kelvin.optional
      attribute? :sku,          Types::String.optional
    end

    def initialize(socket_factory: -> { UDPSocket.new })
      @socket_factory = socket_factory
    end

    def turn(ip, on)          = send_command(ip, "turn",       { "value" => on ? 1 : 0 })
    def brightness(ip, value) = send_command(ip, "brightness", { "value" => value.to_i })
    def request_status(ip)    = send_command(ip, "devStatus",  {})

    def color(ip, r:, g:, b:)
      send_command(ip, "colorwc",
        { "color" => { "r" => r.to_i, "g" => g.to_i, "b" => b.to_i }, "colorTemInKelvin" => 0 })
    end

    def color_temp(ip, kelvin)
      send_command(ip, "colorwc",
        { "color" => { "r" => 0, "g" => 0, "b" => 0 }, "colorTemInKelvin" => kelvin.to_i })
    end

    def self.scan_request = JSON.generate("msg" => { "cmd" => "scan", "data" => { "account_topic" => "reserve" } })

    # Broadcast a LAN scan to the Govee multicast group so devices announce their IP.
    # In production a real UDP socket is used; in tests the injectable socket factory
    # supplies a fake so no actual multicast traffic is generated.
    def discover
      socket = @socket_factory.call
      socket.setsockopt(Socket::IPPROTO_IP, Socket::IP_MULTICAST_TTL, [ 2 ].pack("C"))
      socket.send(self.class.scan_request, 0, SCAN_MCAST, SCAN_PORT)
    ensure
      begin; socket&.close; rescue StandardError; nil; end
    end

    def self.parse_status(payload)
      data = JSON.parse(payload).dig("msg", "data")
      return nil unless data.is_a?(Hash) && data.key?("onOff")
      color = data["color"] || {}
      Status.new(on: data["onOff"] == 1, brightness: data["brightness"],
                 color_r: color["r"], color_g: color["g"], color_b: color["b"],
                 color_temp_k: data["colorTemInKelvin"], sku: data["sku"])
    rescue JSON::ParserError, Dry::Struct::Error
      nil
    end

    def self.parse_scan(payload)
      data = JSON.parse(payload).dig("msg", "data")
      return nil unless data.is_a?(Hash) && data["ip"] && data["device"]
      { ip: data["ip"], mac: data["device"], sku: data["sku"] }
    rescue JSON::ParserError
      nil
    end

    private

    def send_command(ip, cmd, data)
      socket = @socket_factory.call
      socket.send(JSON.generate("msg" => { "cmd" => cmd, "data" => data }), 0, ip, CMD_PORT)
    ensure
      begin; socket&.close; rescue StandardError; nil; end
    end
  end
end
