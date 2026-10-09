# frozen_string_literal: true

# This migration comes from recording_studio_api (originally 20260730000017)
class CreateRecordingStudioApiApiSettings < ActiveRecord::Migration[8.1]
  def change
    create_table :recording_studio_api_api_settings, id: :uuid do |t|
      t.string :key, null: false
      t.boolean :api_access_enabled, null: false, default: true

      t.timestamps
    end

    add_index :recording_studio_api_api_settings, :key, unique: true
  end
end