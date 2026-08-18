# frozen_string_literal: true

# Reference host wiring: map Recording Studio AI actions onto Accessible roles.
# Hosts should copy this pattern instead of `->(**) { true }`.
module DummyAccessibleAIAuthorization
  ROLE_FOR_ACTION = {
    "recording_studio_ai.view_execution" => :view,
    "recording_studio_ai.execute" => :edit,
    "recording_studio_ai.use_provider_native_tool" => :edit,
    "recording_studio_ai.use_custom_tool" => :edit,
    "recording_studio_ai.submit_batch" => :edit,
    "recording_studio_ai.cancel_batch" => :edit,
    "recording_studio_ai.confirm_custom_tool" => :admin,
    "recording_studio_ai.view_sensitive_execution" => :admin,
    "recording_studio_ai.view_retained_response" => :admin
  }.freeze

  module_function

  def call(action:, attribution:, context: {})
    actor = attribution.initiator
    root = attribution.root_recording
    role = ROLE_FOR_ACTION[action.to_s]
    return false if actor.blank? || root.blank? || role.blank?

    # RecordingStudioAI requires a literal true from authorization_handler.
    RecordingStudioAccessible.authorized?(actor: actor, recording: root, role: role) ? true : false
  end

  def accessible_root_ids(actor:, minimum_role: :view)
    return [] if actor.blank?

    RecordingStudioAccessible.root_recording_ids_for(actor: actor, minimum_role: minimum_role)
  end

  def admin_operator?(actor:)
    accessible_root_ids(actor: actor, minimum_role: :admin).any?
  end
end
