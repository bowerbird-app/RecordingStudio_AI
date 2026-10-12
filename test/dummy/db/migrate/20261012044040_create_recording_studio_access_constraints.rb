# frozen_string_literal: true

class CreateRecordingStudioAccessConstraints < ActiveRecord::Migration[8.1]
  def change
    create_table :recording_studio_access_constraints, id: :uuid do |t|
      t.string :action, null: false
      t.string :allowed_audiences, array: true, null: false, default: []

      t.datetime :created_at, null: false
    end

    add_index :recording_studio_access_constraints, :action,
              name: "index_recording_studio_access_constraints_on_action"
  end
end
