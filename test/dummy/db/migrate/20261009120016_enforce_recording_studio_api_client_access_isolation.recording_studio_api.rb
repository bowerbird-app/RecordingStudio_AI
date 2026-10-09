# frozen_string_literal: true

# This migration comes from recording_studio_api (originally 20260527000016)
class EnforceRecordingStudioApiClientAccessIsolation < ActiveRecord::Migration[8.1]
  def up
    if index_exists?(:recording_studio_api_api_clients, name: "index_recording_studio_api_api_clients_on_access_recording_id")
      remove_index :recording_studio_api_api_clients,
                   name: "index_recording_studio_api_api_clients_on_access_recording_id"
    end
    if index_exists?(:recording_studio_api_api_credentials, name: "index_recording_studio_api_credentials_on_active_access")
      remove_index :recording_studio_api_api_credentials,
                   name: "index_recording_studio_api_credentials_on_active_access"
    end

    unless index_exists?(:recording_studio_api_api_clients, :access_recording_id, name: "index_recording_studio_api_api_clients_on_access_recording_id", unique: true)
      add_index :recording_studio_api_api_clients,
                :access_recording_id,
                unique: true,
                name: "index_recording_studio_api_api_clients_on_access_recording_id"
    end

    return if index_exists?(:recording_studio_api_api_credentials, :api_client_id, name: "index_recording_studio_api_credentials_on_active_client")

    add_index :recording_studio_api_api_credentials,
              :api_client_id,
              unique: true,
              where: "revoked_at IS NULL",
              name: "index_recording_studio_api_credentials_on_active_client"
  end

  def down
    if index_exists?(:recording_studio_api_api_clients, name: "index_recording_studio_api_api_clients_on_access_recording_id")
      remove_index :recording_studio_api_api_clients,
                   name: "index_recording_studio_api_api_clients_on_access_recording_id"
    end
    if index_exists?(:recording_studio_api_api_credentials, name: "index_recording_studio_api_credentials_on_active_client")
      remove_index :recording_studio_api_api_credentials,
                   name: "index_recording_studio_api_credentials_on_active_client"
    end

    unless index_exists?(:recording_studio_api_api_clients, :access_recording_id, name: "index_recording_studio_api_api_clients_on_access_recording_id")
      add_index :recording_studio_api_api_clients,
                :access_recording_id,
                name: "index_recording_studio_api_api_clients_on_access_recording_id"
    end

    return if index_exists?(:recording_studio_api_api_credentials, :access_recording_id, name: "index_recording_studio_api_credentials_on_active_access")

    add_index :recording_studio_api_api_credentials,
              :access_recording_id,
              unique: true,
              where: "revoked_at IS NULL",
              name: "index_recording_studio_api_credentials_on_active_access"
  end
end