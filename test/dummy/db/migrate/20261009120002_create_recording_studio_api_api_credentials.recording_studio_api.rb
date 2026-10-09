# frozen_string_literal: true

# This migration comes from recording_studio_api (originally 20260518000002)
class CreateRecordingStudioApiApiCredentials < ActiveRecord::Migration[8.1]
  def change
    create_table :recording_studio_api_api_credentials, id: :uuid do |t|
      t.references :api_client, null: false, type: :uuid, foreign_key: { to_table: :recording_studio_api_api_clients }
      t.references :access_recording, null: false, type: :uuid, index: true
      t.string :token_public_id, null: false
      t.string :token_digest, null: false
      t.string :token_prefix, null: false
      t.datetime :expires_at
      t.datetime :last_used_at
      t.datetime :revoked_at

      t.timestamps
    end

    add_index :recording_studio_api_api_credentials, :token_public_id, unique: true
    add_index :recording_studio_api_api_credentials, :token_digest, unique: true
    add_index :recording_studio_api_api_credentials,
              :access_recording_id,
              unique: true,
              where: "revoked_at IS NULL",
              name: "index_recording_studio_api_credentials_on_active_access"
  end
end
