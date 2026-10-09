# frozen_string_literal: true

# This migration comes from recording_studio_api (originally 20260815000019)
class AddRuntimeOverridesToRecordingStudioApiApiSettings < ActiveRecord::Migration[8.1]
  def change
    add_column :recording_studio_api_api_settings, :runtime_overrides, :jsonb, null: false, default: {}
  end
end
