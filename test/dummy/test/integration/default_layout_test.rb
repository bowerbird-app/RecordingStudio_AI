# frozen_string_literal: true

require "test_helper"
require "devise/test/integration_helpers"

class DefaultLayoutTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  HOST_ASSET_MARKERS = [
    "application",
    "flat_pack/variables",
    "flat_pack/rich_text",
    "tailwind-",
    "importmap"
  ].freeze

  setup do
    @user = User.create!(email: "default-layout-#{SecureRandom.hex(4)}@example.com", password: "Password123!")
    workspace = Workspace.create!(name: "Default layout workspace")
    @root = RecordingStudio.root_recording_for(workspace)
    grant_accessible!(recording: @root, actor: @user, role: :admin)
    sign_in @user
    switch_to_root!(@root, return_to: "/")
    follow_redirect! if response.redirect?
  end

  test "host pages use the dummy sidebar shell with rounded theme and Flatpack assets" do
    [ root_path, ai_playground_path, gem_config_path, gem_methods_path ].each do |path|
      get path

      assert_response :success, path
      assert_select "html[data-theme='rounded']", count: 1
      assert_select "body[data-theme='rounded']", count: 1
      assert_select "body[data-recording-studio-default-layout='true']", count: 0
      assert_includes response.body, "flat-pack--sidebar-layout"
      assert_includes response.body, "AI Admin"
      HOST_ASSET_MARKERS.each do |marker|
        assert_includes response.body, marker, "#{path} missing #{marker}"
      end
    end
  end

  test "engine admin uses default_layout with Access-only page-nav and Flatpack assets" do
    get "/recording_studio_ai/admin"

    assert_response :success
    assert_gem_admin_shell
    assert_select "table", minimum: 1
  end

  test "engine admin custom tools render Flatpack table cells not a text dump" do
    get "/recording_studio_ai/admin/custom_tools"

    assert_response :success
    assert_gem_admin_shell
    assert_select "table tbody td", text: /Dummy Echo Tool/
  end

  test "engine admin provider batches render Flatpack table cells not a text dump" do
    RecordingStudioAI::Batch.create!(
      status: "completed",
      provider: "openai",
      model: "dummy-batch-model",
      root_recording_id: @root.id,
      initiator_type: "User",
      initiator_id: @user.id,
      initiator_kind: "user"
    )

    get "/recording_studio_ai/admin/batches"

    assert_response :success
    assert_gem_admin_shell
    assert_select "table tbody td", text: /dummy-batch-model/
  end

  test "recording studio admin uses default_layout with Access-only page-nav and Flatpack assets" do
    get "/admin"

    assert_response :success
    assert_gem_admin_shell
  end

  test "devise sign in keeps the application layout" do
    sign_out @user
    get new_user_session_path

    assert_response :success
    assert_select "html[data-theme='rounded']", count: 1
    assert_select "body[data-recording-studio-default-layout='true']", count: 0
    refute_includes response.body, "flat-pack--sidebar-layout"
    assert_includes response.body, "Sign In"
  end

  private

  def assert_gem_admin_shell
    assert_select "html[data-theme='rounded']", count: 1
    assert_select "body[data-theme='rounded']", count: 1
    assert_select "body[data-recording-studio-default-layout='true']", count: 1
    refute_includes response.body, "flat-pack--sidebar-layout"
    assert_select "[data-controller='recording-studio-root-switchable--root-switch-dropdown']", count: 0
    refute_includes response.body, "recording-studio-root-switchable--root-switch-dropdown"
    HOST_ASSET_MARKERS.each do |marker|
      assert_includes response.body, marker, "gem admin missing #{marker}"
    end
  end
end
