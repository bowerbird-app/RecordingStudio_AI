# frozen_string_literal: true

# This migration comes from recording_studio_api (originally 20260519000006)
class CreateRecordingStudioApiOauthClients < ActiveRecord::Migration[8.1]
  def change
    create_table :recording_studio_api_oauth_clients, id: :uuid do |t|
      t.string :name, null: false
      t.string :client_identifier, null: false
      t.string :redirect_uri, null: false
      t.boolean :public_client, null: false, default: true
      t.boolean :active, null: false, default: true

      t.timestamps
    end

    add_index :recording_studio_api_oauth_clients, :client_identifier, unique: true
    add_index :recording_studio_api_oauth_clients, :active
  end
end