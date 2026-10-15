# frozen_string_literal: true

require "test_helper"
require "devise/test/integration_helpers"
require_relative "../../../support/i18n_backend_isolation"

# Behavioral renders: a locale without translations shows loaded/shipped English
# for the saved-reply page via RecordingStudio.t. Uses :de so boot-loaded host
# :en overrides do not interfere with the missing-locale path.
class AiI18nEnglishFallbackTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  PAGE_TITLE = "Saved reply"
  PAGE_SUBTITLE = "What the model sent back."
  ABOUT_TITLE = "About this reply"
  OPEN_CALL = "Open this call"
  CLOSE = "Close"
  HOST_CUT_SHORT = "HOST Cut short"
  GEM_CUT_SHORT = "Cut short"
  CUT_SHORT_KEY = "recording_studio.ai.retained_responses.cut_short"
  CLOSE_KEY = "recording_studio.ai.retained_responses.close"
  PAGE_TITLE_KEY = "recording_studio.ai.retained_responses.page_title"
  BOOT_OVERRIDE = Rails.root.join("config/locales/recording_studio_ai_boot_override.en.yml").freeze

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

  # Must fail on its own if the engine initializer does not register en.yml.
  # Do not call register_shipped_english or run the initializer block here.
  test "ai en.yml path is registered at boot without invoking the initializer block" do
    expected = File.expand_path(RecordingStudioAI::Engine.root.join("config/locales/en.yml"))
    paths = RecordingStudio::Translation.send(:registered_shipped_english_paths)

    assert_includes paths, expected
    assert_equal CLOSE,
                 RecordingStudio::Translation.shipped_english.fetch(CLOSE_KEY)
  end

  test "missing locale without translations renders gem english on saved reply page" do
    retained = create_overview_retained_response!

    I18n.with_locale(:de) do
      refute I18n.exists?(PAGE_TITLE_KEY, :de)

      get "/recording_studio_ai/retained_responses/#{retained.id}"

      assert_response :success
      assert_select "h1", text: PAGE_TITLE
      assert_select "p", text: PAGE_SUBTITLE
      assert_includes list_item_label_texts, OPEN_CALL
      assert_equal PAGE_TITLE, RecordingStudio.t(PAGE_TITLE_KEY)
    end
  end

  test "english render matches gem english strings from main" do
    retained = create_overview_retained_response!

    I18n.with_locale(:en) do
      get "/recording_studio_ai/retained_responses/#{retained.id}"
      assert_response :success
      assert_select "h1", text: PAGE_TITLE
      assert_select "p", text: PAGE_SUBTITLE
      assert_select "h3", text: ABOUT_TITLE
      assert_includes list_item_label_texts, OPEN_CALL
    end
  end

  test "deleted english key on saved reply shows shipped Close without translation missing" do
    retained = create_overview_retained_response!
    I18nBackendIsolation.delete_key!(:en, CLOSE_KEY)
    I18nBackendIsolation.delete_key!(:fr, CLOSE_KEY)

    refute I18n.exists?(CLOSE_KEY, :en)
    refute I18n.exists?(CLOSE_KEY, :fr)

    previous_raise = ActionView::Helpers::TranslationHelper.raise_on_missing_translations

    [false, true].each do |raise_on_missing|
      ActionView::Helpers::TranslationHelper.raise_on_missing_translations = raise_on_missing

      %i[en fr].each do |locale|
        I18n.with_locale(locale) do
          get "/recording_studio_ai/retained_responses/#{retained.id}"

          assert_response :success
          assert_equal CLOSE, close_aria_label
          assert_equal CLOSE, RecordingStudio.t(CLOSE_KEY)
        end
      end
    end
  ensure
    ActionView::Helpers::TranslationHelper.raise_on_missing_translations = previous_raise
    I18n.reload!
  end

  test "boot-loaded host override wins on saved reply for rarely shown key" do
    assert_path_exists BOOT_OVERRIDE
    load_path = I18n.load_path.map { |path| File.expand_path(path) }
    assert_includes load_path, BOOT_OVERRIDE.to_s

    I18n.t(CUT_SHORT_KEY) # force init
    assert_equal HOST_CUT_SHORT, I18n.t(CUT_SHORT_KEY)
    assert_equal HOST_CUT_SHORT, RecordingStudio.t(CUT_SHORT_KEY)

    retained = create_overview_retained_response!(complete: false, truncated: true)
    get "/recording_studio_ai/retained_responses/#{retained.id}"
    assert_response :success

    assert_select "li div.min-w-0.flex-1" do |elements|
      labels = elements.map { |element| element.text.strip }
      host_label = labels.find { |text| text == HOST_CUT_SHORT }
      refute_nil host_label, "expected list label #{HOST_CUT_SHORT.inspect}"
      assert_equal HOST_CUT_SHORT, host_label
      refute_includes labels, GEM_CUT_SHORT
    end
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

  def list_item_label_texts
    css_select("li div.min-w-0.flex-1").map { |element| element.text.strip }
  end

  def close_aria_label
    node = css_select("a[aria-label]").find { |element| element["aria-label"] == CLOSE }
    refute_nil node, "expected Close aria-label on page nav"
    node["aria-label"]
  end
end
