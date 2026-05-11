require "config_loader"
require "net/http"
require "uri"
require "json"

class TrmnlPushJob < ApplicationJob
  class PayloadTooLarge < StandardError; end

  MAX_PAYLOAD_BYTES = 2048

  queue_as :default

  def perform
    config = ConfigLoader.load(Rails.root.join("config", config_file_name).to_s)
    url    = config.trmnl_webhook_url
    if url.nil? || url.empty?
      Rails.logger.info("TRMNL push skipped (no webhook URL configured)")
      return
    end

    payload = TrmnlPayloadBuilder.new(config: config).build
    body    = payload.to_json
    bytes   = body.bytesize
    if bytes > MAX_PAYLOAD_BYTES
      raise PayloadTooLarge, "TRMNL payload is #{bytes} B, exceeds #{MAX_PAYLOAD_BYTES} B limit"
    end

    response = self.class.post_json(url, body)
    if response.is_a?(Net::HTTPSuccess)
      Rails.logger.info("TRMNL push: HTTP #{response.code}, #{bytes} B")
    else
      Rails.logger.warn("TRMNL push failed: HTTP #{response.code} #{response.message}")
    end
  rescue StandardError => e
    raise if e.is_a?(PayloadTooLarge)
    Rails.logger.warn("TRMNL push errored: #{e.class}: #{e.message}")
  end

  def self.post_json(url, body)
    uri = URI.parse(url)
    Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                                        open_timeout: 10, read_timeout: 10) do |http|
      req = Net::HTTP::Post.new(uri.request_uri)
      req["Content-Type"] = "application/json"
      req.body = body
      http.request(req)
    end
  end

  private

  def config_file_name
    Rails.env.test? ? "ziwoas.test.yml" : "ziwoas.yml"
  end
end
