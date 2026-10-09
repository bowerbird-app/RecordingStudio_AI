# frozen_string_literal: true

# This migration comes from recording_studio_api (originally 20260519000010)
class CreateRecordingStudioApiOauthSessionAccessTokens < ActiveRecord::Migration[8.1]
  def change
    create_table :recording_studio_api_oauth_session_access_tokens, id: :uuid do |t|
      t.references :oauth_grant_session,
                   null: false,
                   type: :uuid,
                   foreign_key: { to_table: :recording_studio_api_oauth_grant_sessions },
                   index: { name: "index_rsapi_oauth_session_access_tokens_on_session" }
      t.string :token_digest, null: false
      t.string :token_prefix, null: false
      t.datetime :expires_at, null: false
      t.datetime :last_used_at
      t.datetime :revoked_at

      t.timestamps
    end

    add_index :recording_studio_api_oauth_session_access_tokens, :token_digest, unique: true
    add_index :recording_studio_api_oauth_session_access_tokens, :expires_at
    add_index :recording_studio_api_oauth_session_access_tokens, :revoked_at
  end
end