# frozen_string_literal: true

module RecordingStudioAI
  # Prefixed lookups for `recording_studio.ai.*` keys via {RecordingStudio.t}.
  module Copy
    PREFIX = "recording_studio.ai"

    module_function

    def t(key, **)
      RecordingStudio.t("#{PREFIX}.#{key}", **)
    end
  end
end
