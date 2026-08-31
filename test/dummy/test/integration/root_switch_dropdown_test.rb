# frozen_string_literal: true

require "test_helper"
require "devise/test/integration_helpers"

class RootSwitchDropdownTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  test "sign in page renders the addon branding" do
    get new_user_session_path

    assert_response :success
    assert_includes response.body, "Recording Studio AI"
  end

  test "root switcher lists only workspaces the actor can access" do
    user = User.find_or_create_by!(email: "root-switch-test@example.com") do |record|
      record.password = "Password123!"
      record.password_confirmation = "Password123!"
    end

    sign_in user

    granted = Workspace.create!(name: "Dropdown Workspace")
    hidden = Workspace.create!(name: "Hidden Workspace")
    granted_root = RecordingStudio.root_recording_for(granted)
    RecordingStudio.root_recording_for(hidden)
    grant_accessible!(recording: granted_root, actor: user, role: :view)

    get "/recording_studio_root_switchable/v1/root_switch?scope=all_workspaces"

    assert_response :success
    assert_includes response.body, granted.name
    refute_includes response.body, hidden.name
  end

  test "root switch page renders with the host sidebar" do
    user = User.find_or_create_by!(email: "root-switch-page-test@example.com") do |record|
      record.password = "Password123!"
      record.password_confirmation = "Password123!"
    end

    sign_in user

    workspace = Workspace.create!(name: "Switch Page Workspace")
    root = RecordingStudio.root_recording_for(workspace)
    grant_accessible!(recording: root, actor: user, role: :view)

    get "/recording_studio_root_switchable/v1/root_switch?scope=all_workspaces"

    assert_response :success
    assert_includes response.body, workspace.name
    assert_includes response.body, "AI Admin"
    assert_includes response.body, "Recording tree"
    assert_includes response.body, "flat-pack--sidebar-layout"
    assert_select "body[data-recording-studio-default-layout='true']", count: 0
  end

  test "switching returns to the current page when it is a valid internal route" do
    user = User.find_or_create_by!(email: "root-switch-redirect-test@example.com") do |record|
      record.password = "Password123!"
      record.password_confirmation = "Password123!"
    end

    sign_in user

    source_workspace = Workspace.create!(name: "Source Workspace")
    target_workspace = Workspace.create!(name: "Target Workspace")
    target_root_recording = RecordingStudio.root_recording_for(target_workspace)
    RecordingStudio.root_recording_for(source_workspace)
    grant_accessible!(recording: target_root_recording, actor: user, role: :view)

    switch_to_root!(target_root_recording, return_to: "/")

    assert_redirected_to "/"
  end

  test "switching falls back to home when return_to is not a valid internal route" do
    user = User.find_or_create_by!(email: "root-switch-fallback-test@example.com") do |record|
      record.password = "Password123!"
      record.password_confirmation = "Password123!"
    end

    sign_in user

    source_workspace = Workspace.create!(name: "Fallback Source Workspace")
    target_workspace = Workspace.create!(name: "Fallback Target Workspace")
    target_root_recording = RecordingStudio.root_recording_for(target_workspace)
    RecordingStudio.root_recording_for(source_workspace)
    grant_accessible!(recording: target_root_recording, actor: user, role: :view)

    switch_to_root!(target_root_recording, return_to: "/not-a-real-route")

    assert_redirected_to "/"
  end

  test "switching to an ungranted workspace is rejected" do
    user = User.create!(email: "root-switch-denied-#{SecureRandom.hex(4)}@example.com", password: "Password123!")
    sign_in user

    private_workspace = Workspace.create!(name: "Private Switch Workspace")
    private_root = RecordingStudio.root_recording_for(private_workspace)

    switch_to_root!(private_root, return_to: "/")

    assert_response :unprocessable_entity
    assert_match(/not available/i, response.body)
  end
end
