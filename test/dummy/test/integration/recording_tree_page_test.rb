# frozen_string_literal: true

require "test_helper"
require "devise/test/integration_helpers"

class RecordingTreePageTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  test "recording tree page requires authentication" do
    get "/recording_tree"

    assert_redirected_to new_user_session_path
  end

  test "recording tree page renders selected root hierarchy" do
    user = User.create!(email: "recording-tree-#{SecureRandom.hex(4)}@example.com", password: "Password123!")
    sign_in user

    workspace = Workspace.create!(name: "Tree Workspace")
    root_recording = RecordingStudio.root_recording_for(workspace)

    patch "/recording_studio_root_switchable/v1/root_switch", params: {
      scope: "all_workspaces",
      root_switch: {
        root_recording_id: root_recording.id,
        return_to: "/recording_tree"
      }
    }
    follow_redirect!

    assert_response :success
    assert_includes response.body, "Recording tree"
    assert_includes response.body, workspace.name
    assert_includes response.body, "no access"
  end

  test "sidebar includes a link to recording tree page" do
    user = User.create!(email: "recording-tree-sidebar-#{SecureRandom.hex(4)}@example.com", password: "Password123!")
    sign_in user

    Workspace.create!(name: "Sidebar tree workspace")

    get "/"

    assert_response :success
    assert_includes response.body, "Recording tree"
    assert_includes response.body, "/recording_tree"
  end
end
