# frozen_string_literal: true

# Thin host wrapper around RecordingStudioAI::AccessibleAuthorization.
# Prefer the gem module in new hosts; keep these helpers for dummy wiring.
module DummyAccessibleAIAuthorization
  module_function

  def call(action:, attribution:, context: {})
    RecordingStudioAI::AccessibleAuthorization.call(
      action: action,
      attribution: attribution,
      context: context
    )
  end

  def accessible_root_ids(actor:, minimum_role: :view)
    RecordingStudioAI::AccessibleAuthorization.accessible_root_ids(
      actor: actor,
      minimum_role: minimum_role
    )
  end

  def admin_operator?(actor:)
    RecordingStudioAI::AccessibleAuthorization.admin_operator?(actor: actor)
  end
end
