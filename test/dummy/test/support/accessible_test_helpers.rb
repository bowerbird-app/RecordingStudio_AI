# frozen_string_literal: true

module AccessibleTestHelpers
  ROLE_RANK = {
    "view" => 1,
    "edit" => 2,
    "admin" => 3
  }.freeze

  def grant_accessible!(recording:, actor:, role:)
    raise ArgumentError, "recording must be persisted" unless recording.respond_to?(:persisted?) && recording.persisted?
    raise ArgumentError, "actor must be persisted" unless actor.respond_to?(:persisted?) && actor.persisted?

    current_role = RecordingStudioAccessible.role_for(actor: actor, recording: recording)
    return if role_covers?(current_role, role)

    requested = role.to_sym
    if requested == :admin
      bootstrap = RecordingStudioAccessible.bootstrap_owner_access!(recording: recording, actor: actor)
      return bootstrap if bootstrap.success?
    end

    manager = grantor_for(recording)
    manager ||= bootstrap_grantor!(recording)
    result = RecordingStudioAccessible.grant_access(
      recording: recording,
      actor: actor,
      role: role,
      manager_actor: manager
    )
    raise result.error unless result.success?

    result
  end

  def switch_to_root!(root_recording, return_to: "/")
    patch "/recording_studio_root_switchable/v1/root_switch", params: {
      scope: "all_workspaces",
      root_switch: {
        root_recording_id: root_recording.id,
        return_to: return_to
      }
    }
  end

  private

  def grantor_for(recording)
    RecordingStudioAccessible.access_recordings_for(recording).filter_map do |access_recording|
      grant = access_recording.recordable
      next unless grant.respond_to?(:actor) && grant.respond_to?(:role)
      next unless grant.role.to_s == "admin"

      grant.actor
    end.first
  end

  def bootstrap_grantor!(recording)
    grantor = User.create!(
      email: "grantor-#{SecureRandom.hex(4)}@example.com",
      password: "Password123!"
    )
    bootstrap = RecordingStudioAccessible.bootstrap_owner_access!(recording: recording, actor: grantor)
    return grantor if bootstrap.success?

    existing = grantor_for(recording)
    raise bootstrap.error unless existing

    existing
  end

  def role_covers?(current_role, required_role)
    return false if current_role.nil?

    (ROLE_RANK[current_role.to_s] || 0) >= (ROLE_RANK[required_role.to_s] || 0)
  end
end
