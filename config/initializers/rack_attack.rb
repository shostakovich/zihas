class Rack::Attack
  # Generous LAN limits: the dashboard polls /api/live every few seconds.
  throttle("api/ip", limit: 120, period: 1.minute) do |req|
    req.ip if req.path.start_with?("/api/")
  end

  # Switching real devices: tighter.
  throttle("switch/ip", limit: 20, period: 1.minute) do |req|
    req.ip if req.path.match?(%r{\A/plugs/[^/]+/switch\z}) && req.post?
  end
end

Rack::Attack.enabled = !Rails.env.test?
