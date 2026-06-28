# lib/govees/platform_api.rb
require "json"
require "net/http"
require "uri"
require "securerandom"

module Govees
  # Govee Platform API (documented, API-key only). Status codes are in the JSON
  # body, not the HTTP status. Raises Error on transport or body-code failure.
  class PlatformApi
    class Error < StandardError; end

    BASE = "https://openapi.api.govee.com"

    def initialize(api_key:, http: Net::HTTP, open_timeout: 5, read_timeout: 10,
                   clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
      @api_key      = api_key
      @http         = http
      @open_timeout = open_timeout
      @read_timeout = read_timeout
      @clock        = clock
    end

    def devices
      body = get("/router/api/v1/user/devices")
      Array(body["data"])
    end

    def state(sku:, device:)
      body = post("/router/api/v1/device/state", payload: { "sku" => sku, "device" => device })
      caps = body.dig("payload", "capabilities") || []
      caps.each_with_object({}) { |c, h| h[c["instance"]] = c.dig("state", "value") }
    end

    def scenes(sku:, device:)
      body = post("/router/api/v1/device/scenes", payload: { "sku" => sku, "device" => device })
      Array(body.dig("payload", "capabilities", 0, "parameters", "options"))
    end

    def control(sku:, device:, type:, instance:, value:)
      post("/router/api/v1/device/control",
           payload: { "sku" => sku, "device" => device,
                      "capability" => { "type" => type, "instance" => instance, "value" => value } })
      true
    end

    private

    def get(path)  = request(Net::HTTP::Get.new(uri(path)))
    def post(path, payload:)
      req = Net::HTTP::Post.new(uri(path))
      req.body = JSON.generate("requestId" => SecureRandom.uuid, "payload" => payload)
      request(req)
    end

    def uri(path) = URI.join(BASE, path)

    def request(req)
      req["Govee-API-Key"] = @api_key
      req["Content-Type"]  = "application/json"
      u = req.uri
      res = @http.start(u.host, u.port, use_ssl: true,
                        open_timeout: @open_timeout, read_timeout: @read_timeout) { |h| h.request(req) }
      raise Error, "HTTP #{res.code}" unless res.is_a?(Net::HTTPSuccess)
      body = JSON.parse(res.body)
      raise Error, "code #{body['code']}: #{body['message'] || body['msg']}" unless body["code"].to_i == 200
      body
    rescue JSON::ParserError => e
      raise Error, "invalid JSON: #{e.message}"
    end
  end
end
