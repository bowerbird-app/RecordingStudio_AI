# frozen_string_literal: true

class ChangeRecordingStudioAccessesRoleToString < ActiveRecord::Migration[8.1]
  def up
    reject_unknown_integers!

    change_column_default :recording_studio_accesses, :role, nil

    change_column :recording_studio_accesses, :role, :string, null: false, using: <<~SQL.squish
      CASE role
        WHEN 0 THEN 'view'
        WHEN 1 THEN 'edit'
        WHEN 2 THEN 'admin'
      END
    SQL

    change_column_default :recording_studio_accesses, :role, "view"
  end

  def down
    reject_unknown_names!

    change_column_default :recording_studio_accesses, :role, nil

    change_column :recording_studio_accesses, :role, :integer, null: false, using: <<~SQL.squish
      CASE role
        WHEN 'view' THEN 0
        WHEN 'edit' THEN 1
        WHEN 'admin' THEN 2
      END
    SQL

    change_column_default :recording_studio_accesses, :role, 0
  end

  private

  def reject_unknown_integers!
    unknown = select_values(<<~SQL.squish).map { |value| Integer(value) }.sort
      SELECT DISTINCT role FROM recording_studio_accesses WHERE role NOT IN (0, 1, 2)
    SQL
    return if unknown.empty?

    raise ActiveRecord::IrreversibleMigration,
          "Unexpected recording_studio_accesses.role values: #{unknown.join(', ')}"
  end

  def reject_unknown_names!
    unknown = select_values(<<~SQL.squish).map(&:to_s).sort
      SELECT DISTINCT role FROM recording_studio_accesses WHERE role NOT IN ('view', 'edit', 'admin')
    SQL
    return if unknown.empty?

    raise ActiveRecord::IrreversibleMigration,
          "Cannot roll back while custom access roles exist: #{unknown.join(', ')}"
  end
end
