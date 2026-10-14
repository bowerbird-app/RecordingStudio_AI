# frozen_string_literal: true

require "recording_studio_ai/translation"

module RecordingStudioAI
  # Prefixed lookups for `recording_studio.ai.*` keys.
  # Delegates to {Translation} so missing locales fall back to loaded English,
  # then the caller `default:`, then the gem-shipped `en.yml` table.
  module Copy
    PREFIX = "recording_studio.ai"

    module_function

    def t(key, **)
      RecordingStudioAI.t("#{PREFIX}.#{key}", **)
    end
  end
end
