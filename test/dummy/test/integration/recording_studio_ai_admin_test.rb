# frozen_string_literal: true

require "test_helper"

class RecordingStudioAIAdminTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @user = User.create!(email: "admin-#{SecureRandom.hex(4)}@example.com", password: "password123")
    workspace = Workspace.create!(name: "Admin only workspace")
    @root_recording = RecordingStudio.root_recording_for(workspace)

    @original_access_recording_resolver = RecordingStudioAdmin.configuration.access_recording_resolver
    @original_required_access_role = RecordingStudioAdmin.configuration.required_access_role
    @original_access_management_authorizer = RecordingStudioAccessible.configuration.access_management_authorizer

    RecordingStudioAdmin.configuration.access_recording_resolver = ->(_context) { @root_recording }
    RecordingStudioAdmin.configuration.required_access_role = :view
    RecordingStudioAccessible.configuration.access_management_authorizer = ->(**) { true }

    grant_accessible!(recording: @root_recording, actor: @user, role: :view)
  end

  teardown do
    RecordingStudioAdmin.configuration.access_recording_resolver = @original_access_recording_resolver
    RecordingStudioAdmin.configuration.required_access_role = @original_required_access_role
    RecordingStudioAccessible.configuration.access_management_authorizer = @original_access_management_authorizer
  end

  test "engine admin redirects unauthenticated visitors to sign in" do
    get "/recording_studio_ai/admin"

    assert_redirected_to new_user_session_path
  end

  test "admin root remains available" do
    sign_in @user

    get "/admin"

    assert_response :success
    assert_includes response.body, "Recording Studio AI"
    assert_includes response.body, "flat_pack/variables"
    assert_includes response.body, "tailwind-"
  end

  test "legacy AI engine admin path is not routable" do
    sign_in @user

    get "/admin/recording_studio_ai/admin/runs"

    assert_response :not_found
  end

  test "engine admin custom tools index renders registered tools" do
    sign_in @user

    get "/recording_studio_ai/admin/custom_tools"

    assert_response :success
    assert_includes response.body, "Dummy Echo Tool"
    refute_includes response.body, "version_admin_custom_tool"
  end
end
