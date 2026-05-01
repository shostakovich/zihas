require "net/http"
require "uri"
require "digest"
require "rexml/document"

class FritzDectClient
  class Error < StandardError; end

  Reading = Struct.new(:apower_w, :aenergy_wh, keyword_init: true)

  NETWORK_ERRORS = [
    Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout,
    Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ENETUNREACH,
    Errno::ETIMEDOUT, SocketError, EOFError,
  ].freeze

  def initialize(host:, user:, password:, timeout: 2)
    @host     = host
    @user     = user
    @password = password
    @timeout  = timeout
    @sid      = nil
  end

  def fetch(plug)
    authenticate! if @sid.nil?
    power_mw  = fetch_value(plug.ain, "getswitchpower")
    energy_wh = fetch_value(plug.ain, "getswitchenergy")
    Reading.new(apower_w: power_mw / 1000.0, aenergy_wh: energy_wh.to_f)
  rescue *NETWORK_ERRORS => e
    raise Error, "#{e.class}: #{e.message}"
  end

  private

  def fetch_value(ain, cmd)
    response = with_reauth { get_homeauto(ain, cmd) }
    raise Error, "HTTP #{response.code} from #{@host}" unless response.is_a?(Net::HTTPSuccess)
    body = response.body.to_s.strip
    raise Error, "blank response from #{@host}" if body.empty?
    Integer(body)
  rescue ArgumentError
    raise Error, "unexpected response from #{@host}: #{body}"
  end

  def with_reauth
    response = yield
    if response.code == "403"
      @sid = nil
      authenticate!
      response = yield
      raise Error, "HTTP 403 from #{@host} after re-auth" if response.code == "403"
    end
    response
  end

  def get_homeauto(ain, cmd)
    uri = URI("http://#{@host}/webservices/homeautoswitch.lua")
    uri.query = URI.encode_www_form(switchcmd: cmd, ain: ain, sid: @sid)
    get(uri)
  end

  def authenticate!
    uri = URI("http://#{@host}/login_sid.lua")
    response = get(uri)
    raise Error, "HTTP #{response.code} during auth" unless response.is_a?(Net::HTTPSuccess)
    doc = REXML::Document.new(response.body)
    challenge = doc.elements["SessionInfo/Challenge"]&.text
    raise Error, "no challenge in auth response" if challenge.nil?

    md5 = Digest::MD5.hexdigest("#{challenge}-#{@password}".encode("UTF-16LE").b)
    uri.query = URI.encode_www_form(username: @user, response: "#{challenge}-#{md5}")
    response = get(uri)
    raise Error, "HTTP #{response.code} during auth" unless response.is_a?(Net::HTTPSuccess)
    doc = REXML::Document.new(response.body)
    sid = doc.elements["SessionInfo/SID"]&.text
    raise Error, "authentication failed for user #{@user}" if sid.nil? || sid == "0000000000000000"
    @sid = sid
  end

  def get(uri)
    Net::HTTP.start(uri.host, uri.port,
                    open_timeout: @timeout, read_timeout: @timeout) do |http|
      http.request(Net::HTTP::Get.new(uri.request_uri))
    end
  end
end
