# frozen_string_literal: true

RecordingStudio.configure do |config|
  # Registered delegated_type recordables (strings or classes)
  config.recordable_types = [ "Workspace", "Folder", "Page" ]
  config.require_recordable_declarations = true
  config.app_name = "Recording Studio AI"

  # Actor resolver for events when no actor is explicitly supplied
  config.actor = -> { Current.actor }

  # Core 7 denies record! and create_root_recording! unless an authorizer is
  # set. A present actor may write, including a new root where root_recording
  # is nil. Seeds and tests record before access exists. Do not set
  # allow_unauthorized_writes.
  config.authorize_write = ->(actor:, **) { actor.present? }

  # Emit ActiveSupport::Notifications events
  config.event_notifications_enabled = true

  # Idempotency behavior for log_event!
  config.idempotency_mode = :return_existing # or :raise

  # Recordable duplication strategy for revisions
  config.recordable_dup_strategy = :dup

  config.enable_capability(:accessible, on: "Workspace")
  config.enable_capability(:accessible, on: "Folder")
  config.enable_capability(:accessible, on: "Page")
end
