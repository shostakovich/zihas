Rails.application.routes.draw do
  root "dashboard#index"

  get "/reports", to: "reports#index"
  get "/weather", to: "weather#index"

  get "/api/today", to: "api#today"
  get "/api/today/summary", to: "api#today_summary"
  get "/api/history", to: "api#history"
  get "/api/live", to: "api#live"

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  get "up" => "rails/health#show", as: :rails_health_check
end
