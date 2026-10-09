# frozen_string_literal: true

class AdminRoot < ApplicationRecord
  include RecordingStudio::Recordable
  include RecordingStudioAdmin::AllowsAdminSections

  recording_studio_recordable label: "Admin", root: true, shared: false
  RecordingStudio.enable_capability(:accessible, on: self)
  RecordingStudio.enable_capability(:api_access_point, on: self)

  recording_studio_admin_sections do
    section :recording_studio_ai
  end
end
