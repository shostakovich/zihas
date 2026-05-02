class ReportsController < ApplicationController
  def index
    @report = EnergyReport.new(
      params: report_params,
      plugs: app_config.plugs,
      timezone: app_config.timezone,
      electricity_price_eur_per_kwh: app_config.electricity_price_eur_per_kwh
    ).build
  end

  private

  def report_params
    params.permit(:preset, :start_date, :end_date, :selected_date)
  end

end
