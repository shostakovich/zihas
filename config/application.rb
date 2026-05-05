require_relative "boot"

require "rails"
# Pick the frameworks you want:
require "active_model/railtie"
require "active_job/railtie"
require "active_record/railtie"
# require "active_storage/engine"
require "action_controller/railtie"
# require "action_mailer/railtie"
# require "action_mailbox/engine"
# require "action_text/engine"
require "action_view/railtie"
require "action_cable/engine"
require "rails/test_unit/railtie"

require "yaml"
require "tzinfo"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module Ziwoas
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 8.1

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    config.autoload_lib(ignore: %w[assets tasks])

    # Read the IANA timezone from the user config (config/ziwoas[.test].yml) so
    # that Time.zone, ActiveRecord datetime attributes and Rails helpers all use
    # the same zone the weather sync was already configured with. Falls back to
    # Europe/Berlin when the YAML isn't present (e.g. asset precompile in the
    # Docker build) or doesn't parse.
    config.time_zone = begin
      yaml_path = File.join(__dir__, Rails.env.test? ? "ziwoas.test.yml" : "ziwoas.yml")
      raw = YAML.safe_load_file(yaml_path)
      tz = raw.is_a?(Hash) ? raw["timezone"] : nil
      TZInfo::Timezone.get(tz) if tz.is_a?(String) && !tz.empty?
      tz.is_a?(String) && !tz.empty? ? tz : "Europe/Berlin"
    rescue Errno::ENOENT, Psych::Exception, TZInfo::InvalidTimezoneIdentifier
      "Europe/Berlin"
    end
  end
end
