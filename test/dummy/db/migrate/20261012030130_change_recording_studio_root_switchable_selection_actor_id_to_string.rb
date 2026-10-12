# frozen_string_literal: true

class ChangeRecordingStudioRootSwitchableSelectionActorIdToString < ActiveRecord::Migration[8.1]
  def up
    return unless table_exists?(:recording_studio_root_switchable_selections)
    return unless column_exists?(:recording_studio_root_switchable_selections, :actor_id)

    change_column :recording_studio_root_switchable_selections,
                  :actor_id,
                  :string,
                  using: "actor_id::text"
  end

  def down
    return unless table_exists?(:recording_studio_root_switchable_selections)
    return unless column_exists?(:recording_studio_root_switchable_selections, :actor_id)

    change_column :recording_studio_root_switchable_selections,
                  :actor_id,
                  :uuid,
                  using: "actor_id::uuid"
  end
end
