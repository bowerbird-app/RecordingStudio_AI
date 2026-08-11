# frozen_string_literal: true

RecordingStudioAI::Engine.routes.draw do
  namespace :admin do
    root to: "overview#show"
    resource :overview, only: :show, controller: :overview
    resources :runs, only: %i[index show]
    resources :custom_tools, only: %i[index], param: :key do
      get "versions/:version", action: :show, on: :member, as: :version
    end
    resource :provider_native_tools, only: :show
    resources :batches, only: %i[index show]
    resources :retained_responses, only: :show
  end
end
