# frozen_string_literal: true

require "test_helper"
require "devise/test/integration_helpers"

class AdminAiI18nTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @user = User.create!(email: "admin-ai-i18n-#{SecureRandom.hex(4)}@example.com", password: "Password123!")
    workspace = Workspace.create!(name: "Admin AI i18n workspace")
    @root = RecordingStudio.root_recording_for(workspace)
    grant_accessible!(recording: @root, actor: @user, role: :admin)
    sign_in @user
    switch_to_root!(@root, return_to: "/")
    follow_redirect! if response.redirect?
  end

  test "AI admin section renders literal English chrome from gem locales" do
    get "/admin/sections/recording_studio_ai"

    assert_response :success
    assert_includes response.body, "Recording Studio AI"
    assert_includes response.body, "Calls, tools, batches, and saved replies"
    assert_includes response.body, "AI Calls"
    assert_includes response.body, "Custom Tool Calls"
    assert_includes response.body, "Estimated token usage"
    assert_includes response.body, "AI calls"
    assert_equal "Recording Studio AI",
                 I18n.t("recording_studio.ai.admin.section.title", default: "Recording Studio AI")
  end

  test "AI calls screen renders literal English title and subtitle" do
    get "/admin/screens/ai_calls"

    assert_response :success
    assert_includes response.body, "AI Calls"
    assert_includes response.body,
                    "Run-level execution history across generation, streaming, batch, decision, and tool operations."
    assert_equal "AI calls trend",
                 I18n.t("recording_studio.ai.admin.screens.ai_calls.chart_title", default: "AI calls trend")
  end

  test "saved reply page still renders wave-1 English with defaults" do
    retained = create_overview_retained_response!
    get "/recording_studio_ai/retained_responses/#{retained.id}"

    assert_response :success
    assert_includes response.body, "Saved reply"
    assert_includes response.body, "What the model sent back."
    assert_includes response.body, "Open this call"
  end

  private

  def create_overview_retained_response!
    run = RecordingStudioAI::Run.create!(
      operation: "generation",
      status: "completed",
      root_recording_id: @root.id,
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
      truncated: false,
      byte_size: 12,
      content_text: "retained body",
      expires_at: 7.days.from_now
    )
  end
end
