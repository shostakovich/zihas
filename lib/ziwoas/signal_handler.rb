module Ziwoas
  class SignalHandler
    def self.install(app)
      %w[INT TERM].each do |sig|
        Signal.trap(sig) { app.stop! }
      end
    end
  end
end
