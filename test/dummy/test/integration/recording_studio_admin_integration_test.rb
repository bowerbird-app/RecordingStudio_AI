# frozen_string_literal: true

require "test_helper"

class RecordingStudioAdminIntegrationTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @user = User.create!(email: "admin-surface-#{SecureRandom.hex(4)}@example.com", password: "password123")
    workspace = Workspace.create!(name: "Admin surface workspace")
    @root_recording = RecordingStudio.root_recording_for(workspace)
    @original_access_recording_resolver = RecordingStudioAdmin.configuration.access_recording_resolver
    @original_required_access_role = RecordingStudioAdmin.configuration.required_access_role
    @original_access_management_authorizer = RecordingStudioAccessible.configuration.access_management_authorizer
    RecordingStudioAdmin.configuration.access_recording_resolver = ->(_context) { @root_recording }
    RecordingStudioAdmin.configuration.required_access_role = :view
    RecordingStudioAccessible.configuration.access_management_authorizer = ->(**) { true }
  end

  teardown do
    RecordingStudioAdmin.configuration.access_recording_resolver = @original_access_recording_resolver
    RecordingStudioAdmin.configuration.required_access_role = @original_required_access_role
    RecordingStudioAccessible.configuration.access_management_authorizer = @original_access_management_authorizer
  end

  test "recording studio admin surface requires authentication" do
    get "/admin"

    assert_redirected_to new_user_session_path
  end

  test "recording studio admin surface includes recording studio ai section" do
    grant_result = RecordingStudioAccessible.grant_access(recording: @root_recording, actor: @user, role: :view)
    assert grant_result.success?, grant_result.error
    sign_in @user
    patch "/recording_studio_root_switchable/v1/root_switch", params: {
      scope: "all_workspaces",
      root_switch: {
        root_recording_id: @root_recording.id,
        return_to: "/"
      }
    }
    follow_redirect!

    get "/admin"

    assert_response :success
    assert_includes response.body, "Recording Studio AI"
    assert_includes response.body, "href=\"/admin/screens/recording_studio_ai_overview\""
    refute_includes response.body, "/admin/screens/recording_studio_ai_overview?anchor_url="
    refute_includes response.body, "/admin/recording_studio_ai/admin"
    assert_includes response.body, "Close"
    assert_includes response.body, "href=\"/\""
    refute_includes response.body, "Recording tree"
    refute_includes response.body, "AI Admin"
  end
end
