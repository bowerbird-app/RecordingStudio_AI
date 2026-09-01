# frozen_string_literal: true

RecordingStudioAI::Engine.routes.draw do
  namespace :admin do
    root to: "overview#show"
    resource :overview, only: :show, controller: :overview
    resources :runs, only: :show
    resource :provider_native_tools, only: :show
    resources :batches, only: :show
    resources :retained_responses, only: :show
  end
end
