# frozen_string_literal: true

require "i18n"

module RecordingStudioAI
  module Copy
    PREFIX = "recording_studio.ai"

    module_function

    def t(key, **options)
      I18n.t("#{PREFIX}.#{key}", **options)
    end
  end
end
