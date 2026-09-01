# frozen_string_literal: true

RecordingStudioAI::Engine.routes.draw do
  namespace :admin do
    resources :runs, only: :show
    resource :provider_native_tools, only: :show
    resources :batches, only: :show
    resources :retained_responses, only: :show
  end
end
