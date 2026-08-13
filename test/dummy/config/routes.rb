require "sidekiq/web"

Rails.application.routes.draw do
  devise_for :users

  authenticate :user do
    mount Sidekiq::Web => "/sidekiq"
  end

  # RecordingStudio engine is data/API-focused and has no browser root route.
  # Keep legacy links working by redirecting the base path to the app home.
  get "/recording_studio", to: redirect("/"), as: nil
  mount RecordingStudio::Engine, at: "/recording_studio"
  mount RecordingStudioAI::Engine, at: "/recording_studio_ai"
  mount RecordingStudioRootSwitchable::Engine, at: "/recording_studio_root_switchable"
  recording_studio_admin_for :admin, at: "/admin", root_section: :recording_studio_ai

  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  # Defines the root path route ("/")
  get "recording_tree", to: "recording_tree#show"
  get "install", to: "install#show"
  get "config", to: "config#show", as: :gem_config
  get "tables", to: "tables#show", as: :gem_tables
  get "methods", to: "methods#show", as: :gem_methods
  get "ai_playground", to: "ai_playground#show"
  post "ai_playground", to: "ai_playground#create"
  post "ai_playground/stream", to: "ai_playground#stream", as: :stream_ai_playground
  root "home#index"
end
