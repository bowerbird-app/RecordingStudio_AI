# frozen_string_literal: true

module RecordingStudioAI
  # Map AI actions onto Recording Studio Accessible roles for a root recording.
  # Requires the recording-studio-accessible gem. Hosts should wire:
  #
  #   config.authorization_handler = RecordingStudioAI::AccessibleAuthorization.method(:call)
  #
  # Do not replace this with `->(**) { true }`.
  module AccessibleAuthorization
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

    def call(action:, attribution:, context: {}) # rubocop:disable Lint/UnusedMethodArgument -- handler contract
      ensure_accessible!

      actor = attribution&.initiator
      root = attribution&.root_recording
      role = ROLE_FOR_ACTION[action.to_s]
      return false if actor.blank? || root.blank? || role.blank?

      # RecordingStudioAI requires a literal true from authorization_handler.
      allowed = ::RecordingStudioAccessible.authorized?(actor: actor, recording: root, role: role)
      allowed.equal?(true)
    end

    def accessible_root_ids(actor:, minimum_role: :view)
      ensure_accessible!
      return [] if actor.blank?

      ::RecordingStudioAccessible.root_recording_ids_for(actor: actor, minimum_role: minimum_role)
    end

    def admin_operator?(actor:)
      accessible_root_ids(actor: actor, minimum_role: :admin).any?
    end

    def ensure_accessible!
      return if defined?(::RecordingStudioAccessible)

      raise LoadError,
            "RecordingStudioAI::AccessibleAuthorization requires the recording-studio-accessible gem"
    end
    private_class_method :ensure_accessible!
  end
end
