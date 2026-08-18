# frozen_string_literal: true

require "test_helper"
require "devise/test/integration_helpers"

class RecordingTreePageTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  test "recording tree page requires authentication" do
    get "/recording_tree"

    assert_redirected_to new_user_session_path
  end

  test "recording tree page renders selected root hierarchy for granted actors" do
    user = User.create!(email: "recording-tree-#{SecureRandom.hex(4)}@example.com", password: "Password123!")
    sign_in user

    workspace = Workspace.create!(name: "Tree Workspace")
    root_recording = RecordingStudio.root_recording_for(workspace)
    grant_accessible!(recording: root_recording, actor: user, role: :view)

    switch_to_root!(root_recording, return_to: "/recording_tree")
    follow_redirect!

    assert_response :success
    assert_includes response.body, "Recording tree"
    assert_includes response.body, workspace.name
    assert_includes response.body, "view access"
  end

  test "recording tree page shows empty state when no workspace is selected" do
    user = User.create!(email: "recording-tree-empty-#{SecureRandom.hex(4)}@example.com", password: "Password123!")
    sign_in user

    get "/recording_tree"

    assert_response :success
    assert_includes response.body, "Nothing selected"
    assert_includes response.body, "Switch to a workspace to see its tree."
  end
    user = User.create!(email: "recording-tree-sidebar-#{SecureRandom.hex(4)}@example.com", password: "Password123!")
    sign_in user

    Workspace.create!(name: "Sidebar tree workspace")

    get "/"

    assert_response :success
    assert_includes response.body, "Recording tree"
    assert_includes response.body, "/recording_tree"
  end
end
