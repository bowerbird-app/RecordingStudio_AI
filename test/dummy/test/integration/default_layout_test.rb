# frozen_string_literal: true

require "test_helper"
require "devise/test/integration_helpers"

class DefaultLayoutTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @user = User.create!(email: "default-layout-#{SecureRandom.hex(4)}@example.com", password: "Password123!")
    workspace = Workspace.create!(name: "Default layout workspace")
    @root = RecordingStudio.root_recording_for(workspace)
    grant_accessible!(recording: @root, actor: @user, role: :admin)
    sign_in @user
    switch_to_root!(@root, return_to: "/")
    follow_redirect! if response.redirect?
  end

  test "authenticated pages use recording studio default layout with rounded theme" do
    get root_path

    assert_response :success
    assert_select "html[data-theme='rounded']", count: 1
    assert_select "body[data-theme='rounded']", count: 1
    assert_select "body[data-recording-studio-default-layout='true']", count: 1
    assert_select "[data-controller='recording-studio-root-switchable--root-switch-dropdown']", count: 0
    refute_includes response.body, "recording-studio-root-switchable--root-switch-dropdown"
  end

  test "playground config and methods keep default layout without a root switch dropdown" do
    [ ai_playground_path, gem_config_path, gem_methods_path ].each do |path|
      get path

      assert_response :success, path
      assert_select "body[data-recording-studio-default-layout='true']", count: 1
      assert_select "html[data-theme='rounded']", count: 1
      assert_select "body[data-theme='rounded']", count: 1
      assert_select "[data-controller='recording-studio-root-switchable--root-switch-dropdown']", count: 0
    end
  end

  test "devise sign in keeps the application layout" do
    sign_out @user
    get new_user_session_path

    assert_response :success
    assert_select "html[data-theme='rounded']", count: 1
    assert_select "body[data-recording-studio-default-layout='true']", count: 0
    assert_includes response.body, "Sign In"
  end
end
