class Workspace < ApplicationRecord
  recording_studio_recordable label: "Workspace", root: true, allowed_parent_types: []
  RecordingStudio.enable_capability(:accessible, on: self)
  RecordingStudio.enable_capability(:api_access_point, on: self)
end

