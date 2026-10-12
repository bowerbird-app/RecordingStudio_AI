# frozen_string_literal: true

require "test_helper"
require_relative "support/i18n_backend_isolation"
require "recording_studio_ai/admin/recording_studio_ai_widgets"

class AdminI18nTest < ActiveSupport::TestCase
  Copy = RecordingStudioAI::Copy

  def setup
    ensure_engine_locale_loaded!
  end

  def test_admin_section_and_screen_chrome_resolve_to_literal_english
    I18n.with_locale(:en) do
      assert_equal "Recording Studio AI", Copy.t("admin.section.title", default: "Recording Studio AI")
      assert_equal "Calls, tools, batches, and saved replies",
                   Copy.t("admin.section.subtitle", default: "Calls, tools, batches, and saved replies")
      assert_equal "AI Calls", Copy.t("admin.section.links.calls", default: "AI Calls")
      assert_equal "AI Calls", Copy.t("admin.screens.ai_calls.title", default: "AI Calls")
      assert_equal "Open saved reply", Copy.t("admin.open_saved_reply", default: "Open saved reply")
      assert_equal "AI calls", Copy.t("admin.widgets.ai_calls_windows.title", default: "AI calls")
      assert_equal "Last 30 days", Copy.t("common.last_30_days", default: "Last 30 days")
      assert_equal "1st attempt", Copy.t("admin.attempt_kinds.primary", default: "1st attempt")
      assert_equal "After tools", Copy.t("admin.attempt_kinds.continuation", default: "After tools")
    end
  end

  def test_admin_dsl_source_uses_copy_for_render_time_chrome
    section = File.read(File.expand_path("../lib/recording_studio_ai/admin/section.rb", __dir__))
    screen = File.read(File.expand_path("../lib/recording_studio_ai/admin/ai_calls/screen.rb", __dir__))
    widget = File.read(
      File.expand_path("../lib/recording_studio_ai/admin/ai_calls/widgets/ai_calls_windows.rb", __dir__)
    )
    resource = File.read(
      File.expand_path("../lib/recording_studio_ai/admin/recording_studio_ai_retained_responses/resource.rb", __dir__)
    )

    assert_includes section, 'Copy.t("admin.section.title"'
    assert_includes section, "text: ->(_context) { Copy.t("
    assert_not_includes section, 'title "Recording Studio AI"'
    assert_not_includes section, 'text: "AI Calls"'

    assert_includes screen, 'Copy.t("admin.screens.ai_calls.title"'
    assert_not_includes screen, 'title "AI Calls"'
    assert_includes screen, 'title: "Created"'

    assert_includes widget, 'Copy.t("admin.widgets.ai_calls_windows.title"'
    assert_includes widget, 'Copy.t("common.last_30_days"'
    assert_not_includes widget, 'title "AI calls"'

    assert_includes resource, 'Copy.t("admin.open_saved_reply"'
    assert_not_includes resource, 'text: "Open saved reply"'
  end

  def test_attempt_kind_label_keeps_constant_and_resolves_at_call_time
    widgets = AdminScreens::RecordingStudioAIWidgets
    english = AdminScreens::RecordingStudioAIWidgets::ATTEMPT_KIND_LABELS.fetch("primary")

    assert_equal "1st attempt", english
    I18n.with_locale(:en) do
      assert_equal "1st attempt", widgets.attempt_kind_label("primary")
      assert_equal "After tools", widgets.attempt_kind_label("continuation")
    end
  end

  def test_attempt_kind_label_uses_non_english_locale_with_english_fallback_default
    widgets = AdminScreens::RecordingStudioAIWidgets

    I18nBackendIsolation.with_snapshot do
      I18n.available_locales = I18n.available_locales | [:zz]
      I18n.backend.store_translations(:zz, {
                                        recording_studio: {
                                          ai: {
                                            admin: {
                                              attempt_kinds: {
                                                primary: "Premier essai"
                                              }
                                            }
                                          }
                                        }
                                      })

      I18n.with_locale(:zz) do
        assert_equal "Premier essai", widgets.attempt_kind_label("primary")
        assert_equal "Retry", widgets.attempt_kind_label("retry")
      end
    end
  end

  private

  def ensure_engine_locale_loaded!
    locale_path = File.expand_path("../config/locales/en.yml", __dir__)
    expanded = I18n.load_path.map { |path| File.expand_path(path) }
    return if expanded.include?(locale_path)

    # Setup-only: gem unit tests boot without Rails auto-loading engine locales.
    I18n.load_path << locale_path
    I18n.backend.load_translations
  end
end
