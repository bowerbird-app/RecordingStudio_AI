# frozen_string_literal: true

RecordingStudio.configure do |config|
  # Registered delegated_type recordables (strings or classes)
  config.recordable_types = [ "Workspace", "Folder", "Page" ]
  config.require_recordable_declarations = true
  config.app_name = "Recording Studio AI"

  # Actor resolver for events when no actor is explicitly supplied
  config.actor = -> { Current.actor }

  # Recording Studio 6.5 denies writes when this is unset. Access rows use
  # Accessible's creation context (grant and bootstrap). Other writes need
  # :edit on the root. A present actor is not a write policy.
  config.authorize_write = lambda { |actor:, root_recording:, recordable:, **|
    next false unless actor.is_a?(User) && actor.persisted?
    next false unless root_recording

    if defined?(RecordingStudio::Access) && recordable.is_a?(RecordingStudio::Access)
      next true if RecordingStudioAccessible::AccessCreationContext.allowed?

      RecordingStudioAccessible.authorized?(
        actor: actor,
        recording: root_recording,
        role: :admin
      )
    else
      RecordingStudioAccessible.authorized?(
        actor: actor,
        recording: root_recording,
        role: :edit
      )
    end
  }

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
