require "aggregator"
require "config_loader"
require "tzinfo"

class AggregatorJob < ApplicationJob
  queue_as :default

  def perform(today: Date.today, backup_dir: Rails.root.join("storage", "backup").to_s)
    config = ConfigLoader.load(Rails.root.join("config", config_file_name).to_s)
    tz = TZInfo::Timezone.get(config.timezone)
    aggregator = Aggregator.new(timezone: tz)

    Rails.logger.info("aggregator: starting scheduled run")
    aggregator.run_once(today: today)
    aggregator.backup!(backup_dir)
    Rails.logger.info("aggregator: done")
  end

  private

  def config_file_name
    Rails.env.test? ? "ziwoas.test.yml" : "ziwoas.yml"
  end
end
