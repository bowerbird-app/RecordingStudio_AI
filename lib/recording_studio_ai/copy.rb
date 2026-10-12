# frozen_string_literal: true

require "i18n"

module RecordingStudioAI
  module Copy
    PREFIX = "recording_studio.ai"

    module_function

    def t(key, **)
      I18n.t("#{PREFIX}.#{key}", **)
    end
  end
end
