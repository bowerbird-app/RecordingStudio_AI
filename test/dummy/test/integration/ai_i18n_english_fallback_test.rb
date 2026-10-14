# frozen_string_literal: true

require "test_helper"
require "devise/test/integration_helpers"

# Behavioral renders: a locale without translations shows loaded/shipped English
# for the saved-reply page. Uses :de so boot-loaded host :en overrides do not
# interfere with the missing-locale path.
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

  test "shipped english table is loaded at boot before any call" do
    table = RecordingStudioAI::Translation.shipped_english
    refute_nil table
    refute_empty table
    assert_equal "Close", table.fetch("recording_studio.ai.retained_responses.close")
  end

  test "rails reloader reset yields a new shipped english table object" do
    before = RecordingStudioAI::Translation.shipped_english
    begin
      Rails.application.reloader.reload!
    rescue RecordingStudioMetrics::Errors::DuplicateRegistration
      # Metrics re-registration is unrelated; mirror the engine to_prepare path.
      RecordingStudioAI::Translation.reset_shipped_english!
      RecordingStudioAI::Translation.shipped_english
    end
    after = RecordingStudioAI::Translation.shipped_english

    refute_same before, after
    assert_equal before, after
    assert_predicate after, :frozen?
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
    delete_loaded_translation!(:en, key)
    delete_loaded_translation!(:fr, key)

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
                 RecordingStudioAI.t("recording_studio.ai.retained_responses.cut_short")

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

  def delete_loaded_translation!(locale, full_key)
    I18n.exists?(full_key, locale)
    parts = full_key.split(".").map(&:to_sym)
    leaf = parts.pop
    translations = I18n.backend.send(:translations)
    locale_key = locale.to_sym
    translations[locale_key] = translations[locale_key].dup if translations[locale_key].frozen?

    node = translations[locale_key]
    parts.each do |part|
      break unless node.is_a?(Hash) && node[part].is_a?(Hash)

      node[part] = node[part].dup if node[part].frozen?
      node = node[part]
    end
    node.delete(leaf) if node.is_a?(Hash)
  end
end
