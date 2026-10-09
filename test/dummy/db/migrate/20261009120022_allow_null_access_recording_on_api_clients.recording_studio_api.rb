# frozen_string_literal: true

# This migration comes from recording_studio_api (originally 20260831000020)
class AllowNullAccessRecordingOnApiClients < ActiveRecord::Migration[8.1]
  def change
    change_column_null :recording_studio_api_api_clients, :access_recording_id, true
  end
end
