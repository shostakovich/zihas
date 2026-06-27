# lib/govees/bridge.rb
require "mqtt"
require "json"
require "socket"
require "ipaddr"
require "govees/lan_client"
require "govees/platform_api"
require "govees/device_registry"
require "govees/state_store"
require "govees/command_router"
require "govees/reconciler"

module Govees
  # Orchestrates the govees bridge: owns one MQTT publisher + a command
  # subscriber, the LAN listener/poller and the API poller threads, and the
  # collaborators. Publishes govees/<key>/{config,state}; consumes govees/<key>/set.
  class Bridge
    CONFIG_TOPIC = "govees/%s/config".freeze
    STATE_TOPIC  = "govees/%s/state".freeze
    SET_FILTER   = "govees/+/set".freeze

    def initialize(mqtt_config:, govee_config:, api:, logger:,
                   lan: nil, registry: nil, store: nil, router: nil, reconciler: nil,
                   mqtt_factory: nil, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
      @mqtt_config = mqtt_config
      @cfg         = govee_config
      @logger      = logger
      @clock       = clock
      @stopping    = false
      @lan        = lan        || LanClient.new
      @registry   = registry   || DeviceRegistry.new(api: api, logger: logger, names: govee_config.names)
      @store      = store      || StateStore.new(pending_window_s: govee_config.pending_window_seconds, clock: clock)
      @router     = router     || CommandRouter.new(registry: @registry, lan: @lan, api: api, store: @store, logger: logger)
      @reconciler = reconciler || Reconciler.new(registry: @registry, lan: @lan, api: api, store: @store, logger: logger)
      @mqtt_factory   = mqtt_factory || -> { MQTT::Client.new(host: @mqtt_config.host, port: @mqtt_config.port) }
      @publisher      = nil
      @command_client = nil
      @listener_socket = nil
    end

    def publish_config(device)
      payload = JSON.generate(
        "sku"                => device.sku,
        "name"               => device.name,
        "room"               => device.room,
        "supports_color"     => device.supports_color,
        "supports_color_temp" => device.supports_color_temp,
        "zones"              => device.zones,
        "scenes"             => device.scenes,
      )
      # Adjustment 2: retain is positional per real MQTT::Client#publish signature
      publisher.publish(format(CONFIG_TOPIC, device.key), payload, true)
    end

    def publish_state(key, state)
      # Adjustment 2: retain is positional per real MQTT::Client#publish signature
      publisher.publish(format(STATE_TOPIC, key), JSON.generate(state), true)
    end

    # Command path — always publishes (user command must always be reflected).
    def on_set(key, payload_string)
      verb  = JSON.parse(payload_string)
      state = @router.handle(key, verb)
      publish_state(key, state) if state
    rescue JSON::ParserError => e
      @logger.warn("Govees::Bridge: invalid set JSON for #{key}: #{e.message}")
    end

    def run
      @registry.refresh!
      listener = listener_thread   # start listener FIRST so scan replies are caught
      @lan.discover                # broadcast multicast scan after listener is up
      @registry.all.each { |d| publish_config(d); @lan.request_status(d.ip) if d.ip }
      threads = [ command_thread, listener, lan_poller_thread, api_poller_thread ]
      threads.each(&:join)
    ensure
      begin; @publisher&.disconnect; rescue StandardError; nil; end
    end

    def stop!
      @stopping = true
      begin; @listener_socket&.close; rescue StandardError; nil; end
      begin; @command_client&.disconnect; rescue StandardError; nil; end
    end

    private

    def publisher
      @publisher ||= begin
        c = @mqtt_factory.call; c.connect; c
      end
    end

    def command_thread
      Thread.new do
        Thread.current.name = "govees_command"
        @command_client = @mqtt_factory.call
        @command_client.connect
        @command_client.subscribe(SET_FILTER)
        @command_client.get { |topic, payload| on_set(topic.split("/")[1], payload) }
      rescue => e
        @logger.error("Govees::Bridge command: #{e.class}: #{e.message}")
      end
    end

    def listener_thread
      Thread.new do
        Thread.current.name = "govees_listener"
        @listener_socket = UDPSocket.new
        # Set reuse options BEFORE bind so multiple processes can share the port.
        @listener_socket.setsockopt(Socket::SOL_SOCKET, Socket::SO_REUSEADDR, true)
        begin
          @listener_socket.setsockopt(Socket::SOL_SOCKET, Socket::SO_REUSEPORT, true)
        rescue Errno::ENOPROTOOPT
          nil  # SO_REUSEPORT not available on all platforms; best-effort
        end
        @listener_socket.bind("0.0.0.0", LanClient::LISTEN_PORT)
        # Join the Govee multicast group so scan + devStatus replies are received.
        mreq = IPAddr.new("239.255.255.250").hton + IPAddr.new("0.0.0.0").hton
        @listener_socket.setsockopt(Socket::IPPROTO_IP, Socket::IP_ADD_MEMBERSHIP, mreq)
        until @stopping
          payload, addr = @listener_socket.recvfrom(2048)
          handle_datagram(payload, addr[3])
        end
      rescue => e
        @logger.error("Govees::Bridge listener: #{e.class}: #{e.message}") unless @stopping
      end
    end

    # A datagram is either a scan reply (registers IP) or a devStatus reply.
    # Adjustment 1: only publish when res[:changed] is truthy — avoids
    # republishing identical retained state every ~8 s LAN tick.
    def handle_datagram(payload, sender_ip)
      if (scan = LanClient.parse_scan(payload))
        @registry.record_lan_ip(scan[:mac], scan[:ip])
        return
      end
      status = LanClient.parse_status(payload)
      return unless status
      device = @registry.all.find { |d| d.ip == sender_ip }
      return unless device
      res = @reconciler.apply_lan(device.key, status)
      publish_state(device.key, res[:published]) if res && res[:changed]
    end

    def lan_poller_thread
      Thread.new do
        Thread.current.name = "govees_lan_poller"
        until @stopping
          @lan.discover  # re-discover each tick to catch DHCP IP changes
          @registry.all.each { |d| @lan.request_status(d.ip) if d.ip }
          sleep_interruptible(@cfg.lan_poll_seconds)
        end
      rescue => e
        @logger.error("Govees::Bridge lan_poller: #{e.message}")
      end
    end

    # Adjustment 1: only publish when res[:changed] is truthy — avoids
    # needlessly re-triggering the subscriber on identical API poll results.
    def api_poller_thread
      Thread.new do
        Thread.current.name = "govees_api_poller"
        until @stopping
          sleep_interruptible(@cfg.api_poll_seconds)
          break if @stopping
          @reconciler.api_tick.each { |key, res| publish_state(key, res[:published]) if res && res[:changed] }
        end
      rescue => e
        @logger.error("Govees::Bridge api_poller: #{e.message}")
      end
    end

    def sleep_interruptible(seconds)
      deadline = Time.now + seconds
      sleep([ deadline - Time.now, 1 ].min) while Time.now < deadline && !@stopping
    end
  end
end
