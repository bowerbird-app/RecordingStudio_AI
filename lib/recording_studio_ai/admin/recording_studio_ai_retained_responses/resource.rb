# frozen_string_literal: true

module AdminScreens
  class RecordingStudioAIRetainedResponsesResource < RecordingStudioAdmin::Resource
    key "recording_studio_ai_retained_responses"
    section "recording_studio_ai"

    action :show,
           text: "Open saved reply",
           url: lambda { |row, _context|
             RecordingStudioAI::Engine.routes.url_helpers.retained_response_path(row)
           },
           visible_if: lambda { |row, context|
             run = RecordingStudioAIWidgets.response_run(row)
             root = context.root_recording
             run && root && run.root_recording_id == root.id
           }
  end
end
