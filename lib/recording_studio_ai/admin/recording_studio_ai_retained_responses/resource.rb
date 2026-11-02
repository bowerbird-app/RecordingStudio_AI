# frozen_string_literal: true

module AdminScreens
  class RecordingStudioAIRetainedResponsesResource < RecordingStudioAdmin::Resource
    key "recording_studio_ai_retained_responses"
    section "recording_studio_ai"

    action :show,
           text: ->(*) { Copy.t("admin.open_saved_reply") },
           url: lambda { |row, _context|
             RecordingStudioAI::Engine.routes.url_helpers.retained_response_path(row)
           },
           visible_if: lambda { |row, context|
             RecordingStudioAIWidgets.saved_reply_listed?(row, context)
           }
  end
end
