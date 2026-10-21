# frozen_string_literal: true

module RecordingStudioAI
  class Engine < ::Rails::Engine
    isolate_namespace RecordingStudioAI

    initializer "recording_studio_ai.inflections", before: :set_autoloaders do
      ActiveSupport::Inflector.inflections(:en) { |inflect| inflect.acronym "AI" }
    end

    initializer "recording_studio_ai.register_shipped_english",
                before: "recording_studio.load_shipped_english" do
      RecordingStudio::Translation.register_shipped_english(
        root.join("config/locales/en.yml")
      )
    end

    initializer "recording_studio_ai.logs" do
      config.to_prepare { RecordingStudioAI::LogsRegistration.register! }
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
