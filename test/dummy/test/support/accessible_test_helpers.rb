# frozen_string_literal: true

module AccessibleTestHelpers
  def grant_accessible!(recording:, actor:, role:)
    previous = RecordingStudioAccessible.configuration.access_management_authorizer
    RecordingStudioAccessible.configuration.access_management_authorizer = ->(**) { true }
    result = RecordingStudioAccessible.grant_access(
      recording: recording,
      actor: actor,
      role: role,
      manager_actor: actor
    )
    raise result.error unless result.success?

    result
  ensure
    RecordingStudioAccessible.configuration.access_management_authorizer = previous
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
end
