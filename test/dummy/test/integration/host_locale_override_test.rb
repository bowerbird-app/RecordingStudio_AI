# frozen_string_literal: true

require "test_helper"
require "devise/test/integration_helpers"
require_relative "../../../support/i18n_backend_isolation"

class HostLocaleOverrideTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  HOST_SECTION_TITLE = "HOST Recording Studio AI"
  HOST_PAGE_TITLE = "HOST Saved reply"
  OVERRIDE_PATH = Rails.root.join("test/locales/recording_studio_ai_host_override.en.yml")

  setup do
    @user = User.create!(email: "host-override-#{SecureRandom.hex(4)}@example.com", password: "Password123!")
    workspace = Workspace.create!(name: "Host override workspace")
    @root = RecordingStudio.root_recording_for(workspace)
    grant_accessible!(recording: @root, actor: @user, role: :admin)
    sign_in @user
    switch_to_root!(@root, return_to: "/")
    follow_redirect! if response.redirect?
  end

  test "host locale override wins over gem English on a real admin page" do
    assert_path_exists OVERRIDE_PATH
    refute_includes OVERRIDE_PATH.to_s, "config/locales",
                    "override must stay test-only so the default dummy UI keeps gem English"

    I18nBackendIsolation.with_snapshot do
      I18n.load_path << OVERRIDE_PATH.to_s
      I18n.backend.load_translations

      get "/admin/sections/recording_studio_ai"

      assert_response :success
      assert_includes response.body, HOST_SECTION_TITLE
      refute_includes response.body, ">Recording Studio AI<"
    end
  end

  test "host locale override wins on the saved-reply page" do
    I18nBackendIsolation.with_snapshot do
      I18n.load_path << OVERRIDE_PATH.to_s
      I18n.backend.load_translations

      retained = create_overview_retained_response!
      get "/recording_studio_ai/retained_responses/#{retained.id}"

      assert_response :success
      assert_includes response.body, HOST_PAGE_TITLE
      refute_includes response.body, ">Saved reply<"
    end
  end

  test "default dummy UI still shows gem English when no test override is loaded" do
    get "/admin/sections/recording_studio_ai"

    assert_response :success
    assert_includes response.body, "Recording Studio AI"
    refute_includes response.body, HOST_SECTION_TITLE
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
