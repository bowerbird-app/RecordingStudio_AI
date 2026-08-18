# frozen_string_literal: true

require "test_helper"

class RetainedResponsesAdminAccessTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @user = User.create!(email: "retained-#{SecureRandom.hex(4)}@example.com", password: "password123")
    @workspace = Workspace.create!(name: "Retained view workspace")
    @root_recording = RecordingStudio.root_recording_for(@workspace)
    @other_workspace = Workspace.create!(name: "Retained other workspace")
    @other_root = RecordingStudio.root_recording_for(@other_workspace)
  end

  test "unauthenticated visitors are sent to sign in" do
    retained = create_retained_response!(root: @root_recording)

    get "/recording_studio_ai/admin/retained_responses/#{retained.id}"

    assert_redirected_to new_user_session_path
  end

  test "signed-in users without Accessible grants are forbidden like Recording Studio Admin" do
    assert RecordingStudioAI.const_defined?(:RecordingStudioAdminAuthorization)
    refute RecordingStudioAI::Admin.const_defined?(:RecordingStudioAdminAuthorization, false)

    retained = create_retained_response!(root: @root_recording)
    sign_in @user

    get "/recording_studio_ai/admin/retained_responses/#{retained.id}"

    assert_response :forbidden
  end

  test "view grant opens the retained body the same way as the AI Responses screen" do
    grant_accessible!(recording: @root_recording, actor: @user, role: :view)
    retained = create_retained_response!(root: @root_recording, content_text: "viewable retained body")
    sign_in @user
    switch_to_root!(@root_recording)

    get "/admin/screens/recording_studio_ai_responses"
    assert_response :success

    get "/admin/screens/recording_studio_ai_responses/table"
    assert_response :success
    assert_includes response.body, "Response ##{retained.id}"

    get "/recording_studio_ai/admin/retained_responses/#{retained.id}"
    assert_response :success
    assert_includes response.body, "viewable retained body"
  end

  test "retained response page still authorizes after a code reload" do
    grant_accessible!(recording: @root_recording, actor: @user, role: :view)
    retained = create_retained_response!(root: @root_recording, content_text: "after reload")
    sign_in @user
    switch_to_root!(@root_recording)

    Rails.application.reloader.reload!

    get "/recording_studio_ai/admin/retained_responses/#{retained.id}"
    assert_response :success
    assert_includes response.body, "after reload"
  end

  test "view grant cannot open a retained response from another root" do
    grant_accessible!(recording: @root_recording, actor: @user, role: :view)
    grant_accessible!(recording: @other_root, actor: @user, role: :view)
    foreign = create_retained_response!(root: @other_root, content_text: "foreign retained body")
    sign_in @user
    switch_to_root!(@root_recording)

    get "/recording_studio_ai/admin/retained_responses/#{foreign.id}"

    assert_response :not_found
    refute_includes response.body, "foreign retained body"
  end

  private

  def create_retained_response!(root:, content_text: "retained body")
    run = RecordingStudioAI::Run.create!(
      operation: "generation",
      status: "completed",
      root_recording_id: root.id,
      initiator_type: "User",
      initiator_id: @user.id,
      initiator_kind: "user",
      started_at: Time.current,
      completed_at: Time.current
    )
    attempt = run.attempts.create!(
      sequence: 1,
      kind: "primary",
      status: "completed",
      provider: "test",
      model: "test-model",
      started_at: Time.current,
      completed_at: Time.current
    )
    RecordingStudioAI::Response.create!(
      attempt: attempt,
      response_type: "generation",
      provider: "test",
      model: "test-model",
      complete: true,
      byte_size: content_text.bytesize,
      content_text: content_text,
      expires_at: 7.days.from_now
    )
  end
end
