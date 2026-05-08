require "json"
require "net/http"
require "uri"
require "openssl"
require "base64"
require "securerandom"

class SwitchBotClient
  BASE_URL = "https://api.switch-bot.com"

  class Error < StandardError; end

  def initialize(token:, secret:, http_timeout: 4)
    @token        = token
    @secret       = secret
    @http_timeout = http_timeout
  end

  def device_status(device_id)
    body = get_json("/v1.1/devices/#{device_id}/status")
    normalize_status(body.fetch("body", {}))
  end

  private

  def get_json(path)
    uri = URI(BASE_URL + path)
    response = Net::HTTP.start(uri.host, uri.port,
                               use_ssl: true,
                               read_timeout: @http_timeout,
                               open_timeout: @http_timeout) do |http|
      req = Net::HTTP::Get.new(uri.request_uri)
      signed_headers.each { |k, v| req[k] = v }
      http.request(req)
    end
    raise Error, "HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)
    json = JSON.parse(response.body)
    code = json["statusCode"]
    raise Error, "SwitchBot API: #{json["message"] || "status #{code}"}" unless code == 100
    json
  rescue JSON::ParserError, Net::OpenTimeout, Net::ReadTimeout, SocketError => e
    raise Error, e.message
  end

  def signed_headers
    t     = (Time.now.to_f * 1000).to_i.to_s
    nonce = SecureRandom.uuid
    sign  = Base64.strict_encode64(
              OpenSSL::HMAC.digest("SHA256", @secret, "#{@token}#{t}#{nonce}")
            )
    {
      "Authorization" => @token,
      "t"             => t,
      "nonce"         => nonce,
      "sign"          => sign,
      "Content-Type"  => "application/json"
    }
  end

  def normalize_status(b)
    {
      temperature:      b["temperature"],
      humidity:         b["humidity"],
      co2:              b["CO2"],
      battery_pct:      b["battery"],
      firmware_version: b["version"],
      raw:              b
    }
  end
end
