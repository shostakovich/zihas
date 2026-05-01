require "fileutils"
require "ziwoas"

Rails.application.config.after_initialize do
  if defined?(Rails::Server) || defined?(Puma)
    # Ensure data directory exists
    FileUtils.mkdir_p(Rails.root.join("data"))

    # Configs
    config_path = Rails.root.join("config", "ziwoas.yml").to_s
    database_path = Rails.root.join("data", "ziwoas.db").to_s

    # Avoid double-booting if multiple puma workers, 
    # though usually after_initialize in single mode is fine.
    unless defined?($ZIWOAS_APP)
      Rails.logger.info "Booting Ziwoas::App background threads..."
      $ZIWOAS_APP = Ziwoas::App.boot(
        config_path: config_path,
        database_path: database_path
      )
      
      at_exit do
        $ZIWOAS_APP.stop! rescue nil
      end
    end
  end
end
