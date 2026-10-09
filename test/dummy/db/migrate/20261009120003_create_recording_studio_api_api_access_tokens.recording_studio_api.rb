# frozen_string_literal: true

# This migration comes from recording_studio_api (originally 20260518000003)
class CreateRecordingStudioApiApiAccessTokens < ActiveRecord::Migration[8.1]
  def change
    create_table :recording_studio_api_api_access_tokens, id: :uuid do |t|
      t.references :api_credential,
                   null: false,
                   type: :uuid,
                   foreign_key: { to_table: :recording_studio_api_api_credentials }
      t.string :token_digest, null: false
      t.string :token_prefix, null: false
      t.datetime :expires_at, null: false
      t.datetime :last_used_at
      t.datetime :revoked_at

      t.timestamps
    end

    add_index :recording_studio_api_api_access_tokens, :token_digest, unique: true
    add_index :recording_studio_api_api_access_tokens, :expires_at
  end
end