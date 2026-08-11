# frozen_string_literal: true

module AdminScreens
  class RecordingStudioAIOverviewScreen < RecordingStudioAdmin::Screen
    key "recording_studio_ai_overview"
    icon :cpu_chip
    title "Recording Studio AI"
    subtitle "Entry point for AI administration views."

              query do |_context|
                     RecordingStudioAI::Run.order(created_at: :desc)
              end
  end
end
