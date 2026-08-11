# frozen_string_literal: true

module AdminScreens
  class RecordingStudioAISection < RecordingStudioAdmin::Section
    key "recording_studio_ai"
    icon :cpu_chip
    title "Recording Studio AI"
    subtitle "Runs, custom tools, provider batches, and retained responses"

    link :overview,
         text: "Overview",
         url: ->(context) { context.admin_screen_path("recording_studio_ai_overview") },
         style: :secondary
  end
end
