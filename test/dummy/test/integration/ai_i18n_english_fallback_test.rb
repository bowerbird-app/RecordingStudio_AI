# frozen_string_literal: true

require "test_helper"
require "devise/test/integration_helpers"
require_relative "../../../support/i18n_backend_isolation"

# Behavioral renders: a locale without translations shows loaded/shipped English
# for the saved-reply page via RecordingStudio.t. Uses :de so boot-loaded host
# :en overrides do not interfere with the missing-locale path.
class AiI18nEnglishFallbackTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @user = User.create!(email: "ai-fallback-#{SecureRandom.hex(4)}@example.com", password: "Password123!")
    workspace = Workspace.create!(name: "AI fallback workspace")
    @root = RecordingStudio.root_recording_for(workspace)
    grant_accessible!(recording: @root, actor: @user, role: :admin)
    sign_in @user
    switch_to_root!(@root, return_to: "/")
    follow_redirect! if response.redirect?
    @previous_locales = I18n.available_locales
    I18n.available_locales = (@previous_locales + %i[en de fr]).uniq
  end

  teardown do
    I18n.locale = I18n.default_locale
    I18n.available_locales = @previous_locales if @previous_locales
  end

  test "this gem en.yml is registered in RecordingStudio shipped english paths" do
    path = RecordingStudioAI::Engine.root.join("config/locales/en.yml").to_s
    registered = RecordingStudio::Translation.send(:registered_shipped_english_paths)

    assert_includes registered, File.expand_path(path)
    assert_equal "Close",
                 RecordingStudio::Translation.shipped_english.fetch(
                   "recording_studio.ai.retained_responses.close"
                 )
  end

  test "missing locale without translations renders gem english on saved reply page" do
    retained = create_overview_retained_response!

    I18n.with_locale(:de) do
      refute I18n.exists?("recording_studio.ai.retained_responses.page_title", :de)

      get "/recording_studio_ai/retained_responses/#{retained.id}"

      assert_response :success
      assert_includes @response.body, "Saved reply"
      assert_includes @response.body, "What the model sent back."
      assert_includes @response.body, "Open this call"
      refute_match(/translation missing:.*recording_studio\.ai/i, @response.body)
    end
  end

  test "english render matches gem english strings from main" do
    retained = create_overview_retained_response!

    I18n.with_locale(:en) do
      get "/recording_studio_ai/retained_responses/#{retained.id}"
      assert_response :success
      assert_includes @response.body, "Saved reply"
      assert_includes @response.body, "What the model sent back."
      assert_includes @response.body, "About this reply"
      assert_includes @response.body, "Open this call"
      refute_match(/translation missing:.*recording_studio\.ai/i, @response.body)
    end
  end

  test "deleted english key on saved reply shows shipped Close without translation missing" do
    retained = create_overview_retained_response!
    key = "recording_studio.ai.retained_responses.close"
    I18nBackendIsolation.delete_key!(:en, key)
    I18nBackendIsolation.delete_key!(:fr, key)

    refute I18n.exists?(key, :en)
    refute I18n.exists?(key, :fr)

    previous_raise = ActionView::Helpers::TranslationHelper.raise_on_missing_translations

    [false, true].each do |raise_on_missing|
      ActionView::Helpers::TranslationHelper.raise_on_missing_translations = raise_on_missing

      %i[en fr].each do |locale|
        I18n.with_locale(locale) do
          get "/recording_studio_ai/retained_responses/#{retained.id}"

          assert_response :success
          assert_includes @response.body, "Close"
          refute_match(/translation missing:.*recording_studio\.ai/i, @response.body)
        end
      end
    end
  ensure
    ActionView::Helpers::TranslationHelper.raise_on_missing_translations = previous_raise
    I18n.reload!
  end

  test "boot-loaded host override wins on saved reply for rarely shown key" do
    boot_override = Rails.root.join("config/locales/recording_studio_ai_boot_override.en.yml")
    assert_path_exists boot_override
    assert_includes I18n.load_path.map { |path| File.expand_path(path) }, boot_override.to_s

    I18n.t("recording_studio.ai.retained_responses.cut_short") # force init
    assert_equal "HOST Cut short", I18n.t("recording_studio.ai.retained_responses.cut_short")
    assert_equal "HOST Cut short",
                 RecordingStudio.t("recording_studio.ai.retained_responses.cut_short")

    retained = create_overview_retained_response!(complete: false, truncated: true)
    get "/recording_studio_ai/retained_responses/#{retained.id}"
    assert_response :success
    assert_includes response.body, "HOST Cut short"
    refute_includes response.body, ">Cut short<"
  end

  private

  def create_overview_retained_response!(complete: true, truncated: false)
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
      complete: complete,
      truncated: truncated,
      byte_size: 12,
      content_text: "retained body",
      expires_at: 7.days.from_now
    )
  end

end
