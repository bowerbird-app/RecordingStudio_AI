# frozen_string_literal: true

# This migration comes from recording_studio_api (originally 20260519000009)
class CreateRecordingStudioApiOauthGrantSessions < ActiveRecord::Migration[8.1]
  def change
    create_table :recording_studio_api_oauth_grant_sessions, id: :uuid do |t|
      t.references :oauth_client,
                   null: false,
                   type: :uuid,
                   foreign_key: { to_table: :recording_studio_api_oauth_clients }
      t.references :access_recording, null: false, type: :uuid, index: true
      t.string :state
      t.datetime :last_used_at
      t.datetime :revoked_at

      t.timestamps
    end

    add_index :recording_studio_api_oauth_grant_sessions, :revoked_at
  end
end