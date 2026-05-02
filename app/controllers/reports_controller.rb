class ReportsController < ApplicationController
  def index
    @report = EnergyReport.new(
      params: report_params,
      plugs: app_config.plugs,
      timezone: app_config.timezone
    ).build
  end

  private

  def report_params
    params.permit(:preset, :start_date, :end_date, :selected_date)
  end

  def app_config
    Rails.application.ziwoas_app.config
  end
end
