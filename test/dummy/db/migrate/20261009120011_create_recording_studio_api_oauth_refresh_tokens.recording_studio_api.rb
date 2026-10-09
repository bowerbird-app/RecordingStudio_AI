# frozen_string_literal: true

# This migration comes from recording_studio_api (originally 20260519000011)
class CreateRecordingStudioApiOauthRefreshTokens < ActiveRecord::Migration[8.1]
  def change
    create_table :recording_studio_api_oauth_refresh_tokens, id: :uuid do |t|
      t.references :oauth_grant_session,
                   null: false,
                   type: :uuid,
                   foreign_key: { to_table: :recording_studio_api_oauth_grant_sessions },
                   index: { name: "index_rsapi_oauth_refresh_tokens_on_session" }
      t.references :previous_refresh_token,
                   null: true,
                   type: :uuid,
                   foreign_key: { to_table: :recording_studio_api_oauth_refresh_tokens }
      t.references :replaced_by,
                   null: true,
                   type: :uuid,
                   foreign_key: { to_table: :recording_studio_api_oauth_refresh_tokens }
      t.string :token_digest, null: false
      t.string :token_prefix, null: false
      t.datetime :expires_at, null: false
      t.datetime :last_used_at
      t.datetime :consumed_at
      t.datetime :revoked_at

      t.timestamps
    end

    add_index :recording_studio_api_oauth_refresh_tokens, :token_digest, unique: true
    add_index :recording_studio_api_oauth_refresh_tokens, :expires_at
    add_index :recording_studio_api_oauth_refresh_tokens, :consumed_at
    add_index :recording_studio_api_oauth_refresh_tokens, :revoked_at
  end
end