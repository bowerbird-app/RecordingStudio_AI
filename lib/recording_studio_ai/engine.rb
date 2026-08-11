# frozen_string_literal: true

module RecordingStudioAI
  class Engine < ::Rails::Engine
    isolate_namespace RecordingStudioAI

    initializer "recording_studio_ai.inflections", before: :set_autoloaders do
      ActiveSupport::Inflector.inflections(:en) { |inflect| inflect.acronym "AI" }
    end
  end
end
