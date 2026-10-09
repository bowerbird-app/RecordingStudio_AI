# frozen_string_literal: true

class AddDependsOnRecordingIdToRecordingStudioAccesses < ActiveRecord::Migration[8.1]
  def change
    add_column :recording_studio_accesses, :depends_on_recording_id, :uuid
    add_index :recording_studio_accesses, :depends_on_recording_id,
              name: "index_recording_studio_accesses_on_depends_on_recording_id"
  end
end
