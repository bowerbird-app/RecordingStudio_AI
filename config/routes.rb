# frozen_string_literal: true

RecordingStudioAI::Engine.routes.draw do
  resources :retained_responses, only: :show
end
