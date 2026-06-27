# lib/govees/lan_client.rb
require "json"
require "socket"

module Govees
  # Pure Govee LAN protocol: serialize commands, send UDP to :4003, parse
  # devStatus + scan replies. No MQTT, no DB. Socket factory is injectable.
  class LanClient
    CMD_PORT   = 4003
    SCAN_MCAST = "239.255.255.250"
    SCAN_PORT  = 4001
    LISTEN_PORT = 4002

    Status = Struct.new(:on, :brightness, :color_r, :color_g, :color_b,
                        :color_temp_k, :sku, keyword_init: true)

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

    def self.parse_status(payload)
      data = JSON.parse(payload).dig("msg", "data")
      return nil unless data.is_a?(Hash) && data.key?("onOff")
      color = data["color"] || {}
      Status.new(on: data["onOff"] == 1, brightness: data["brightness"],
                 color_r: color["r"], color_g: color["g"], color_b: color["b"],
                 color_temp_k: data["colorTemInKelvin"], sku: data["sku"])
    rescue JSON::ParserError
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
