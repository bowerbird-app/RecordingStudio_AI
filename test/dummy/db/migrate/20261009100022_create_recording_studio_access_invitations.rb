# frozen_string_literal: true

class CreateRecordingStudioAccessInvitations < ActiveRecord::Migration[8.1]
  def change
    create_table :recording_studio_access_invitations, id: :uuid do |table|
      invitation_identity_columns(table)
      invitation_lifecycle_columns(table)
      table.timestamps
    end

    add_invitation_indexes
    add_invitation_guards
  end

  private

  def invitation_identity_columns(table)
    table.uuid :recording_id, null: false
    table.string :email, null: false
    table.string :role, null: false
    table.string :token_digest, null: false, limit: 64
    table.string :manager_actor_type, null: false
    table.uuid :manager_actor_id, null: false
  end

  def invitation_lifecycle_columns(table)
    table.string :accepted_by_actor_type
    table.uuid :accepted_by_actor_id
    table.datetime :expires_at, null: false
    table.datetime :last_sent_at, null: false
    table.datetime :accepted_at
    table.datetime :revoked_at
  end

  def add_invitation_indexes
    add_index :recording_studio_access_invitations, %i[recording_id email], **unclosed_email_index
    add_index :recording_studio_access_invitations, :token_digest, unique: true,
                                                                   name: "idx_rs_access_invitations_token_digest"
    add_index :recording_studio_access_invitations, :recording_id
  end

  def unclosed_email_index
    {
      unique: true,
      where: "accepted_at IS NULL AND revoked_at IS NULL",
      name: "idx_rs_access_invitations_one_active"
    }
  end

  def add_invitation_guards
    add_foreign_key :recording_studio_access_invitations, :recording_studio_recordings, column: :recording_id
    add_check_constraint :recording_studio_access_invitations,
                         "accepted_at IS NULL OR revoked_at IS NULL",
                         name: "access_invitations_not_accepted_and_revoked"
  end
end
