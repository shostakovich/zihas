require "mqtt"
require "json"
require "socket"
require "govee_lan_client"

# The only component that speaks Govee UDP. Subscribes to govee/+/command/#,
# translates to LAN commands, binds UDP :listen_port for devStatus replies and
# republishes them to govee/<key>/status. Also polls all lights periodically.
class GoveeMqttBridge
  def initialize(mqtt_config:, govee_config:, logger:,
                 lan_client: GoveeLanClient.new,
                 lights_provider: -> { Light.all.to_a },
                 mqtt_factory: nil)
    @mqtt_config     = mqtt_config
    @govee_config    = govee_config
    @logger          = logger
    @lan             = lan_client
    @lights_provider = lights_provider
    @lights          = @lights_provider.call
    @stopping        = false
    @mqtt_factory    = mqtt_factory || -> {
      MQTT::Client.new(host: @mqtt_config.host, port: @mqtt_config.port)
    }
    @publisher = nil
  end

  def handle_command(topic, payload)
    cmd   = topic.split("/").last
    key   = topic.split("/")[1]
    @lights = @lights_provider.call if cmd == "refresh"
    light = find_by_key(key)
    return @logger.warn("GoveeMqttBridge: unknown light '#{key}'") unless light

    data = JSON.parse(payload)
    case cmd
    when "turn"       then @lan.turn(light.ip_address, data["on"])
    when "brightness" then @lan.brightness(light.ip_address, data["value"])
    when "color"      then @lan.color(light.ip_address, r: data["r"], g: data["g"], b: data["b"])
    when "color_temp" then @lan.color_temp(light.ip_address, data["temp_k"])
    when "refresh"    then nil # status request below is enough
    else return @logger.warn("GoveeMqttBridge: unknown command '#{cmd}'")
    end
    @lan.request_status(light.ip_address)
  rescue JSON::ParserError => e
    @logger.warn("GoveeMqttBridge: invalid command JSON on #{topic}: #{e.message}")
  end

  def handle_datagram(payload, sender_ip)
    status = GoveeLanClient.parse_status(payload)
    return unless status
    light = find_by_ip(sender_ip)
    return unless light

    body = {
      on:           status.on,
      brightness:   status.brightness,
      color_r:      status.color_r,
      color_g:      status.color_g,
      color_b:      status.color_b,
      color_temp_k: status.color_temp_k,
      reachable:    true,
      sku:          status.sku
    }
    publisher.publish("#{@govee_config.topic_prefix}/#{light.key}/status", JSON.generate(body))
  end

  def poll_once
    @lights = @lights_provider.call
    @lights.each { |l| @lan.request_status(l.ip_address) }
  end

  def run
    @publisher = @mqtt_factory.call
    @publisher.connect
    threads = [ command_thread, listener_thread, poller_thread ]
    threads.each(&:join)
  ensure
    begin; @publisher&.disconnect; rescue StandardError; nil; end
  end

  def stop!
    @stopping = true
  end

  private

  def find_by_key(key) = @lights.find { |l| l.key == key }
  def find_by_ip(ip)   = @lights.find { |l| l.ip_address == ip }

  def publisher
    @publisher ||= begin
      c = @mqtt_factory.call
      c.connect
      c
    end
  end

  def command_thread
    Thread.new do
      Thread.current.name = "govee_command"
      consumer = @mqtt_factory.call
      consumer.connect
      consumer.subscribe("#{@govee_config.topic_prefix}/+/command/#")
      consumer.get { |t, p| handle_command(t, p) }
    rescue => e
      @logger.error("GoveeMqttBridge command: #{e.class}: #{e.message}")
    end
  end

  def listener_thread
    Thread.new do
      Thread.current.name = "govee_listener"
      socket = UDPSocket.new
      socket.bind("0.0.0.0", @govee_config.listen_port)
      until @stopping
        payload, addr = socket.recvfrom(2048)
        handle_datagram(payload, addr[3])
      end
    rescue => e
      @logger.error("GoveeMqttBridge listener: #{e.class}: #{e.message}")
    end
  end

  def poller_thread
    Thread.new do
      Thread.current.name = "govee_poller"
      until @stopping
        poll_once
        sleep_interruptible(@govee_config.poll_interval_seconds)
      end
    rescue => e
      @logger.error("GoveeMqttBridge poller: #{e.class}: #{e.message}")
    end
  end

  def sleep_interruptible(seconds)
    deadline = Time.now + seconds
    while Time.now < deadline && !@stopping
      sleep([ deadline - Time.now, 1 ].min)
    end
  end
end
