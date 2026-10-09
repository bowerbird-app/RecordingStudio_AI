# frozen_string_literal: true

# This migration comes from recording_studio_api (originally 20260518000001)
class CreateRecordingStudioApiApiClients < ActiveRecord::Migration[8.1]
  def change
    create_table :recording_studio_api_api_clients, id: :uuid do |t|
      t.references :access_recording, null: false, type: :uuid, index: true
      t.string :name, null: false

      t.timestamps
    end
  end
end
