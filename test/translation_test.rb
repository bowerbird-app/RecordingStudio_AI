# frozen_string_literal: true

require "test_helper"
require_relative "support/i18n_backend_isolation"
require_relative "support/engine_locale"
require "yaml"

# Behavioral coverage for this gem's English via RecordingStudio.t after
# register_shipped_english. Deep RecordingStudio.t contract tests live in core.
class TranslationTest < ActiveSupport::TestCase
  GEM_KEYS = {
    "recording_studio.ai.retained_responses.close" => "Close",
    "recording_studio.ai.retained_responses.page_title" => "Saved reply",
    "recording_studio.ai.retained_responses.page_subtitle" => "What the model sent back.",
    "recording_studio.ai.admin.section.title" => "Recording Studio AI",
    "recording_studio.ai.common.no_prompt" => "No prompt",
    "recording_studio.ai.common.yes" => "Yes"
  }.freeze

  setup do
    ensure_engine_locale_loaded!
    @previous_locales = I18n.available_locales
    I18n.available_locales = (@previous_locales + %i[en fr de]).uniq
  end

  teardown do
    I18n.locale = I18n.default_locale
    I18n.available_locales = @previous_locales if @previous_locales
  end

  # Registration-at-boot (without invoking the initializer block) lives in the
  # dummy integration suite so it can fail if the engine initializer is removed.

  test "deleted loaded english falls back to this gem english via RecordingStudio.t" do
    I18nBackendIsolation.with_snapshot do
      GEM_KEYS.each_key do |key|
        I18nBackendIsolation.delete_key!(:en, key)
        I18nBackendIsolation.delete_key!(:fr, key)
      end

      GEM_KEYS.each do |key, english|
        refute I18n.exists?(key, :en), "#{key} must be absent from loaded :en"
        refute I18n.exists?(key, :fr), "#{key} must be absent from loaded :fr"

        I18n.with_locale(:en) do
          assert_equal english, RecordingStudio.t(key)
          refute_match(/translation missing/i, RecordingStudio.t(key))
        end
        I18n.with_locale(:fr) do
          assert_equal english, RecordingStudio.t(key)
          refute_match(/translation missing/i, RecordingStudio.t(key))
        end
      end
    end
  end

  test "missing locale falls back to loaded english via RecordingStudio.t" do
    I18n.with_locale(:de) do
      GEM_KEYS.each do |key, english|
        refute I18n.exists?(key, :de), "#{key} must be absent in :de for this test"
        assert_equal english, RecordingStudio.t(key),
                     "#{key} should fall back to loaded English when :de has no file"
        refute_match(/translation missing/i, RecordingStudio.t(key))
      end
    end
  end

  test "raise-on-missing style lookups still return gem english for missing locale" do
    I18n.with_locale(:de) do
      assert_raises(I18n::MissingTranslationData) do
        I18n.t("recording_studio.ai.retained_responses.close", locale: :de, raise: true)
      end

      assert_equal "Close", RecordingStudio.t("recording_studio.ai.retained_responses.close")
    end
  end

  test "copy helper delegates to RecordingStudio.t with prefix" do
    I18n.with_locale(:en) do
      assert_equal "Saved reply", RecordingStudioAI::Copy.t("retained_responses.page_title")
      assert_equal RecordingStudio.t("recording_studio.ai.retained_responses.page_title"),
                   RecordingStudioAI::Copy.t("retained_responses.page_title")
    end
  end

  private

  def ensure_engine_locale_loaded!
    EngineLocale.ensure_loaded!
  end
end
