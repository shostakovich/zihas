Rails.application.routes.draw do
  root "dashboard#index"

  get "/reports", to: "reports#index"
  get "/weather", to: "weather#index"
  get "/sensors", to: "sensors#index", as: :sensors
  get "/sensors/series", to: "sensors#series", as: :sensors_series

  get "/switches", to: "switches#index", as: :switches
  resources :rooms, except: [ :show ]
  resources :lights, param: :key, only: %i[index show edit update destroy]

  get "/solakon", to: "solakon#index", as: :solakon
  get "/solakon/history", to: "solakon#history", as: :solakon_history
  patch "/solakon/eps", to: "solakon_controls#eps", as: :solakon_eps
  patch "/solakon/auto_regulation", to: "solakon_controls#auto_regulation", as: :solakon_auto_regulation

  scope "/plugs/:plug_id" do
    post "switch", to: "plug_switches#create", as: :plug_switch
    resources :switch_windows, only: %i[new create edit update destroy]
  end

  scope "/lights/:light_key" do
    post "command", to: "light_switches#create", as: :light_command
  end

  resources :presets, except: [ :show ]
  resources :scenes, except: [ :show ] do
    post :apply, on: :member
  end

  get "/api/today", to: "api#today"
  get "/api/today/summary", to: "api#today_summary"
  get "/api/history", to: "api#history"
  get "/api/live", to: "api#live"

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  get "up" => "rails/health#show", as: :rails_health_check
end
