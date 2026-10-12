# frozen_string_literal: true

class CreateRecordingStudioAccessRules < ActiveRecord::Migration[8.1]
  def change
    create_table :recording_studio_access_rules, id: :uuid do |t|
      t.string :action, null: false
      t.string :audience, null: false

      t.datetime :created_at, null: false
    end

    add_index :recording_studio_access_rules, :action,
              name: "index_recording_studio_access_rules_on_action"
  end
end
