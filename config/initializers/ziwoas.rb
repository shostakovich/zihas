require "fileutils"
require "ziwoas"

Rails.application.config.after_initialize do
  if (defined?(Rails::Server) || defined?(Puma)) && !Rails.env.test?
    FileUtils.mkdir_p(Rails.root.join("data"))
    config_path = Rails.root.join("config", "ziwoas.yml").to_s

    unless Rails.application.ziwoas_app
      if ENV["SKIP_BACKGROUND"]
        Rails.logger.info "Loading Ziwoas::App config without background threads..."
        Rails.application.ziwoas_app = Ziwoas::App.new(config_path)
      else
        Rails.logger.info "Booting Ziwoas::App background threads..."
        Rails.application.ziwoas_app = Ziwoas::App.boot(config_path: config_path)

        at_exit do
          Rails.application.ziwoas_app&.stop!
        end
      end
    end
  end
end
