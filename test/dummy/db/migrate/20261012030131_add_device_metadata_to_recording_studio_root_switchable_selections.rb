# frozen_string_literal: true

class AddDeviceMetadataToRecordingStudioRootSwitchableSelections < ActiveRecord::Migration[8.1]
  COLUMNS = {
    device_label: { type: :string, limit: 255 },
    device_platform: { type: :string, limit: 255 },
    device_browser: { type: :string, limit: 255 },
    device_type: { type: :string, limit: 255 },
    user_agent: { type: :text }
  }.freeze

  def up
    return unless table_exists?(:recording_studio_root_switchable_selections)

    COLUMNS.each do |name, options|
      next if column_exists?(:recording_studio_root_switchable_selections, name)

      add_column :recording_studio_root_switchable_selections, name, options[:type], **options.except(:type)
    end
  end

  def down
    return unless table_exists?(:recording_studio_root_switchable_selections)

    COLUMNS.each_key do |name|
      next unless column_exists?(:recording_studio_root_switchable_selections, name)

      remove_column :recording_studio_root_switchable_selections, name
    end
  end
end
