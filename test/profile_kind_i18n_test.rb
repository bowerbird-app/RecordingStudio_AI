# frozen_string_literal: true

require "test_helper"
require_relative "support/i18n_backend_isolation"
require_relative "support/engine_locale"
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

  def test_high_usage_alert_english_uses_singular_for_one
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

  def test_high_usage_main_style_count_override_renders_raw_integer
    # Main-style "%{count} calls" host override: count: is the raw Integer, so
    # thousands are not delimited (1000, not 1,000). Prefer %{formatted_count}.
    I18nBackendIsolation.with_snapshot do
      I18n.backend.store_translations(:en, {
                                        recording_studio: {
                                          ai: {
                                            admin: {
                                              alerts: {
                                                high_usage: "Unusually high usage today: %{count} calls"
                                              }
                                            }
                                          }
                                        }
                                      })

      I18n.with_locale(:en) do
        # Same kwargs as high_usage_alert_text: formatted_count is ignored when
        # the override string only interpolates %{count}.
        text = RecordingStudioAI::Copy.t(
          "admin.alerts.high_usage",
          count: 1_000,
          formatted_count: "1,000"
        )
        assert_equal "Unusually high usage today: 1000 calls", text
        refute_includes text, "1,000"
      end
    end
  end

  private

  def ensure_engine_locale_loaded!
    EngineLocale.ensure_loaded!
  end
end
