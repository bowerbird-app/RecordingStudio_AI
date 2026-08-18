# frozen_string_literal: true

require "test_helper"

class DummyAccessibleHostHardeningTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @previous_authorizer = RecordingStudioAccessible.configuration.access_management_authorizer
    RecordingStudioAccessible.configuration.access_management_authorizer = ->(**) { true }
  end

  teardown do
    RecordingStudioAccessible.configuration.access_management_authorizer = @previous_authorizer
  end

  test "AI authorization maps Accessible roles instead of always allowing" do
    user = User.create!(email: "ai-auth-#{SecureRandom.hex(4)}@example.com", password: "password123")
    workspace = Workspace.create!(name: "AI auth workspace")
    root = RecordingStudio.root_recording_for(workspace)
    grant_accessible!(recording: root, actor: user, role: :view)

    attribution = RecordingStudioAI::Contracts::Attribution.new(
      root_recording: root,
      initiator: user,
      initiator_kind: "user"
    )

    refute DummyAccessibleAIAuthorization.call(
      action: "recording_studio_ai.execute",
      attribution: attribution,
      context: {}
    )
    assert_equal true, DummyAccessibleAIAuthorization.call(
      action: "recording_studio_ai.view_execution",
      attribution: attribution,
      context: {}
    )

    grant_accessible!(recording: root, actor: user, role: :edit)
    assert_equal true, DummyAccessibleAIAuthorization.call(
      action: "recording_studio_ai.execute",
      attribution: attribution,
      context: {}
    )
    refute DummyAccessibleAIAuthorization.call(
      action: "recording_studio_ai.view_sensitive_execution",
      attribution: attribution,
      context: {}
    )
  end

  test "AI engine admin only lists Accessible roots" do
    user = User.create!(email: "ai-admin-roots-#{SecureRandom.hex(4)}@example.com", password: "password123")
    granted = Workspace.create!(name: "Granted admin root")
    hidden = Workspace.create!(name: "Hidden admin root")
    granted_root = RecordingStudio.root_recording_for(granted)
    hidden_root = RecordingStudio.root_recording_for(hidden)
    grant_accessible!(recording: granted_root, actor: user, role: :view)

    visible_ids = RecordingStudioAI.configuration.admin_visible_roots_resolver.call(
      actor: user,
      controller: Object.new
    )

    assert_includes visible_ids, granted_root.id
    refute_includes visible_ids, hidden_root.id
  end

  test "admin access recording resolver fails closed without grants" do
    user = User.create!(email: "admin-fail-closed-#{SecureRandom.hex(4)}@example.com", password: "password123")
    Workspace.create!(name: "Ungranted admin fallback workspace")
    RecordingStudio.root_recording_for(Workspace.order(:created_at).last)

    context = Struct.new(:current_actor, :controller).new(
      user,
      Struct.new(:current_root_recording).new(RecordingStudio::Recording.where(parent_recording_id: nil).first)
    )

    assert_nil RecordingStudioAdmin.configuration.access_recording_resolver.call(context)
  end

  test "sidekiq is hidden from view-only users and available to admin operators" do
    viewer = User.create!(email: "sidekiq-view-#{SecureRandom.hex(4)}@example.com", password: "password123")
    operator = User.create!(email: "sidekiq-admin-#{SecureRandom.hex(4)}@example.com", password: "password123")
    workspace = Workspace.create!(name: "Sidekiq workspace")
    root = RecordingStudio.root_recording_for(workspace)
    grant_accessible!(recording: root, actor: viewer, role: :view)
    grant_accessible!(recording: root, actor: operator, role: :admin)

    sign_in viewer
    get "/"
    assert_response :success
    refute_includes response.body, "/sidekiq"
    get "/sidekiq"
    assert_response :not_found

    sign_in operator
    get "/"
    assert_response :success
    assert_includes response.body, "/sidekiq"
  end
end
