require "net/http"
require "json"
require "uri"

class ShellyClient
  class Error < StandardError; end

  Reading = Struct.new(:apower_w, :aenergy_wh, keyword_init: true)

  NETWORK_ERRORS = [
    Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout,
    Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ENETUNREACH,
    Errno::ETIMEDOUT, SocketError, EOFError,
  ].freeze

  def initialize(timeout: 2)
    @timeout = timeout
  end

  def fetch(plug)
    host = plug.host
    uri = URI("http://#{host}/rpc/Switch.GetStatus?id=0")
    response = get(uri)
    raise Error, "HTTP #{response.code} from #{host}" unless response.is_a?(Net::HTTPSuccess)

    parse(response.body, host)
  rescue *NETWORK_ERRORS => e
    raise Error, "#{e.class}: #{e.message}"
  end

  private

  def get(uri)
    Net::HTTP.start(uri.host, uri.port,
                    open_timeout: @timeout, read_timeout: @timeout) do |http|
      http.request(Net::HTTP::Get.new(uri.request_uri))
    end
  end

  def parse(body, host)
    data = JSON.parse(body)
    apower  = data["apower"]
    aenergy = data.dig("aenergy", "total")
    raise Error, "missing apower/aenergy from #{host}" if apower.nil? || aenergy.nil?

    Reading.new(apower_w: apower.to_f, aenergy_wh: aenergy.to_f)
  rescue JSON::ParserError => e
    raise Error, "invalid JSON from #{host}: #{e.message}"
  end
end
