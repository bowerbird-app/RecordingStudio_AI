# frozen_string_literal: true

# This migration comes from recording_studio_api (originally 20260519000007)
class CreateRecordingStudioApiOauthAuthorizationCodes < ActiveRecord::Migration[8.1]
  def change
    create_table :recording_studio_api_oauth_authorization_codes, id: :uuid do |t|
      t.references :oauth_client,
                   null: false,
                   type: :uuid,
                   foreign_key: { to_table: :recording_studio_api_oauth_clients }
      t.references :access_recording, null: false, type: :uuid, index: true
      t.string :code_digest, null: false
      t.string :code_prefix, null: false
      t.string :code_challenge, null: false
      t.string :code_challenge_method, null: false
      t.string :redirect_uri, null: false
      t.string :state
      t.datetime :expires_at, null: false
      t.datetime :consumed_at

      t.timestamps
    end

    add_index :recording_studio_api_oauth_authorization_codes, :code_digest, unique: true
    add_index :recording_studio_api_oauth_authorization_codes, :expires_at
    add_index :recording_studio_api_oauth_authorization_codes, :consumed_at
  end
end