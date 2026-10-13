# frozen_string_literal: true

require "test_helper"
require_relative "support/i18n_backend_isolation"
require "recording_studio_ai/admin/recording_studio_ai_widgets"

class ProfileKindI18nTest < ActiveSupport::TestCase
  Widgets = AdminScreens::RecordingStudioAIWidgets

  def setup
    ensure_engine_locale_loaded!
  end

  def test_prompt_message_title_matches_main_for_assistant
    I18n.with_locale(:en) do
      assert_equal "System Prompt", Widgets.prompt_message_title("system")
      assert_equal "User Prompt", Widgets.prompt_message_title("user")
      assert_equal "Assistant", Widgets.prompt_message_title("assistant")
    end
  end

  def test_profile_kind_row_keeps_raw_tokens_and_display_translates
    I18n.with_locale(:en) do
      assert_equal "Generative, Decision",
                   Widgets.profile_kind_display("Generative, Decision")
      assert_equal "Decision", Widgets.profile_kind_display("Decision")
    end
  end

  def test_profile_kind_filter_matches_raw_tokens_when_decision_is_translated
    I18nBackendIsolation.with_snapshot do
      I18n.available_locales = I18n.available_locales | [:zz]
      I18n.backend.store_translations(:zz, {
                                        recording_studio: {
                                          ai: {
                                            common: {
                                              generative: "Génératif",
                                              decision: "Décision"
                                            }
                                          }
                                        }
                                      })

      I18n.with_locale(:zz) do
        assert_equal "Génératif, Décision",
                     Widgets.profile_kind_display("Generative, Decision")
        assert_equal "Décision", Widgets.profile_kind_display("Decision")

        row = Widgets::ProfileRow.new(
          "custom", false, 1, "openai", "gpt-5", "Generative, Decision"
        )
        assert Widgets.profile_row_has_kind?(row, "Generative")
        assert Widgets.profile_row_has_kind?(row, "Decision")
        refute Widgets.profile_row_has_kind?(row, "Décision")
        refute Widgets.profile_row_has_kind?(row, "Génératif")

        assert_equal %w[Generative Decision], Widgets.profile_kind_filter_values.map(&:to_s)
      end
    end
  end

  def test_high_usage_en_yml_uses_one_other_plural_forms
    # Reverting to main's flat string form must fail this test.
    tree = YAML.safe_load_file(
      File.expand_path("../config/locales/en.yml", __dir__),
      aliases: true
    )
    forms = tree.dig("en", "recording_studio", "ai", "admin", "alerts", "high_usage")

    assert_kind_of Hash, forms, "high_usage must be a plural Hash (one/other), not a flat String"
    assert_equal "Unusually high usage today: %{formatted_count} call", forms.fetch("one")
    assert_equal "Unusually high usage today: %{formatted_count} calls", forms.fetch("other")
  end

  def test_high_usage_alert_english_matches_main_for_one
    # Sanctioned English change vs main: singular "call" when count is 1.
    I18n.with_locale(:en) do
      text = RecordingStudioAI::Copy.t(
        "admin.alerts.high_usage",
        count: 1,
        formatted_count: "1"
      )
      assert_equal "Unusually high usage today: 1 call", text
    end
  end

  def test_high_usage_alert_english_matches_main_for_other
    I18n.with_locale(:en) do
      text = RecordingStudioAI::Copy.t(
        "admin.alerts.high_usage",
        count: 20,
        formatted_count: "20"
      )
      delimited = RecordingStudioAI::Copy.t(
        "admin.alerts.high_usage",
        count: 1_000,
        formatted_count: "1,000"
      )

      assert_equal "Unusually high usage today: 20 calls", text
      assert_equal "Unusually high usage today: 1,000 calls", delimited
    end
  end

  def test_high_usage_flat_string_host_override_still_works_for_any_count
    # I18n returns a non-Hash override as-is (no plural lookup).
    I18nBackendIsolation.with_snapshot do
      I18n.backend.store_translations(:en, {
                                        recording_studio: {
                                          ai: {
                                            admin: {
                                              alerts: {
                                                high_usage: "HOST flat high usage: %{formatted_count}"
                                              }
                                            }
                                          }
                                        }
                                      })

      I18n.with_locale(:en) do
        one = RecordingStudioAI::Copy.t(
          "admin.alerts.high_usage",
          count: 1,
          formatted_count: "1"
        )
        many = RecordingStudioAI::Copy.t(
          "admin.alerts.high_usage",
          count: 20,
          formatted_count: "20"
        )

        assert_equal "HOST flat high usage: 1", one
        assert_equal "HOST flat high usage: 20", many
      end
    end
  end

  private

  def ensure_engine_locale_loaded!
    locale_path = File.expand_path("../config/locales/en.yml", __dir__)
    expanded = I18n.load_path.map { |path| File.expand_path(path) }
    return if expanded.include?(locale_path)

    I18n.load_path << locale_path
    I18n.backend.load_translations
  end
end
