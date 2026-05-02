class ApplicationController < ActionController::Base
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes

  private

  def app_config
    @app_config ||= ConfigLoader.load(Rails.root.join("config", config_file_name).to_s)
  end

  def config_file_name
    Rails.env.test? ? "ziwoas.test.yml" : "ziwoas.yml"
  end
end
