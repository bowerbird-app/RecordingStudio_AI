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

  def test_high_usage_alert_uses_numeric_count_and_plural_forms
    I18n.with_locale(:en) do
      one = RecordingStudioAI::Copy.t(
        "admin.alerts.high_usage",
        count: 1,
        formatted_count: "1",
        default: {
          one: "Unusually high usage today: %{formatted_count} call",
          other: "Unusually high usage today: %{formatted_count} calls"
        }
      )
      other = RecordingStudioAI::Copy.t(
        "admin.alerts.high_usage",
        count: 20,
        formatted_count: "20",
        default: {
          one: "Unusually high usage today: %{formatted_count} call",
          other: "Unusually high usage today: %{formatted_count} calls"
        }
      )

      assert_equal "Unusually high usage today: 1 call", one
      assert_equal "Unusually high usage today: 20 calls", other
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
