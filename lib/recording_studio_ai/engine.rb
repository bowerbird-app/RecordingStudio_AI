# frozen_string_literal: true

module RecordingStudioAI
  class Engine < ::Rails::Engine
    isolate_namespace RecordingStudioAI

    initializer "recording_studio_ai.inflections", before: :set_autoloaders do
      ActiveSupport::Inflector.inflections(:en) { |inflect| inflect.acronym "AI" }
    end

    initializer "recording_studio_ai.metrics" do
      config.to_prepare { RecordingStudioAI::Metrics.register! }
    end

    config.to_prepare do
      next unless defined?(RecordingStudioAdmin)

      require "recording_studio_ai/admin_screens"
      AdminScreens.register!
    end
  end
end
