# frozen_string_literal: true

require "test_helper"
require_relative "support/i18n_backend_isolation"
require_relative "support/engine_locale"
require "yaml"
require "action_controller"
require "active_support/core_ext/string/output_safety"

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
    I18n.available_locales = (@previous_locales + %i[en fr de xx]).uniq
  end

  teardown do
    I18n.locale = I18n.default_locale
    I18n.available_locales = @previous_locales if @previous_locales
  end

  test "english locale resolves every sample gem key from en.yml" do
    I18n.with_locale(:en) do
      GEM_KEYS.each do |key, english|
        assert_equal english, RecordingStudioAI.t(key)
        assert_equal english, RecordingStudioAI::Translation.t(key)
      end
    end
  end

  test "shipped english table matches gem en.yml" do
    RecordingStudioAI::Translation.reset_shipped_english!
    en_yml = YAML.safe_load_file(
      File.expand_path("../config/locales/en.yml", __dir__),
      aliases: true
    ).fetch("en").fetch("recording_studio").fetch("ai")

    expected = flatten_locale_keys(en_yml, %w[recording_studio ai])
    table = RecordingStudioAI::Translation.shipped_english
    assert_equal expected, table
    assert_predicate table, :frozen?
    table.each_value { |value| assert_predicate value, :frozen? }
    assert_same table, RecordingStudioAI::Translation.shipped_english,
                "shipped english must be loaded once (no per-call file reload)"
  end

  test "deleted loaded english falls back to shipped gem en.yml text" do
    I18nBackendIsolation.with_snapshot do
      GEM_KEYS.each_key do |key|
        delete_loaded_translation!(:en, key)
        delete_loaded_translation!(:fr, key)
      end

      GEM_KEYS.each do |key, english|
        refute I18n.exists?(key, :en), "#{key} must be absent from loaded :en"
        I18n.with_locale(:en) do
          assert_equal english, RecordingStudioAI.t(key)
          refute_match(/translation missing/i, RecordingStudioAI.t(key))
        end
        I18n.with_locale(:fr) do
          assert_equal english, RecordingStudioAI.t(key)
          refute_match(/translation missing/i, RecordingStudioAI.t(key))
        end
      end
    end
  end

  test "missing locale falls back to loaded english" do
    I18n.with_locale(:de) do
      GEM_KEYS.each do |key, english|
        refute I18n.exists?(key, :de), "#{key} must be absent in :de for this test"
        assert_equal english, RecordingStudioAI.t(key),
                     "#{key} should fall back to loaded English when :de has no file"
        refute_match(/translation missing/i, RecordingStudioAI.t(key))
      end
    end
  end

  test "does not raise for missing locale when callers use raise-on-missing style lookups" do
    I18n.with_locale(:de) do
      assert_raises(I18n::MissingTranslationData) do
        I18n.t("recording_studio.ai.retained_responses.close", locale: :de, raise: true)
      end

      assert_equal "Close", RecordingStudioAI.t("recording_studio.ai.retained_responses.close")
    end
  end

  test "english fallback value matches loaded en backend not a ruby literal table" do
    en_yml = YAML.safe_load_file(
      File.expand_path("../config/locales/en.yml", __dir__),
      aliases: true
    )
    gem_english = en_yml.fetch("en").fetch("recording_studio").fetch("ai")
                        .fetch("retained_responses").fetch("close")

    source = File.read(File.expand_path("../lib/recording_studio_ai/translation.rb", __dir__))
    refute_includes source, gem_english,
                    "Translation helper must not hard-code English; it must read loaded :en"

    I18n.with_locale(:de) do
      assert_equal gem_english, RecordingStudioAI.t("recording_studio.ai.retained_responses.close")
    end
  end

  test "parity matrix non-gem keys match I18n.t" do
    I18nBackendIsolation.with_snapshot do
      I18n.t("recording_studio.ai.retained_responses.close") # force init before store
      I18n.backend.store_translations(:en, {
                                        probe: {
                                          greet: "Hi %{name}",
                                          empty: "",
                                          nil_value: nil,
                                          nest: { a: "A" },
                                          html_key_html: "<b>x</b>",
                                          items: { one: "one item", other: "%{count} items" }
                                        }
                                      })
      I18n.backend.store_translations(:de, { probe: { greet: "Hallo %{name}" } })

      I18n.with_locale(:de) do
        assert_parity("probe.greet", name: "M")
        assert_parity("probe.missing")
        assert_parity("probe.missing", default: "D")
        assert_parity("probe.empty")
        assert_parity("probe.nil_value")
        assert_parity("probe.nest")
        assert_parity("probe.items", count: 1)
        assert_parity("probe.items", count: 5)
        assert_parity(:"probe.greet", name: "M")
        assert_parity(%w[probe.missing probe.greet], name: "M")
        assert_parity("greet", scope: "probe", name: "M")
        assert_raise_parity("probe.missing", raise: true)
        assert_parity("probe.greet", locale: :en, name: "M")
        assert_parity("probe.html_key_html")
      end
    end
  end

  test "parity matrix gem keys cover missing default raise nil empty hash and related options" do
    I18nBackendIsolation.with_snapshot do
      ensure_engine_locale_loaded!
      I18n.backend.load_translations
      key = "recording_studio.ai.retained_responses.close"
      missing = "recording_studio.ai.retained_responses.missing_key_for_parity"
      assert I18n.exists?(key, :en), "fixture en.yml must provide #{key}"

      I18n.backend.store_translations(:en, {
                                        recording_studio: {
                                          ai: {
                                            retained_responses: {
                                              nil_value: nil,
                                              empty_value: "",
                                              nest: { a: "A" },
                                              html_key_html: "<i>g</i>",
                                              items: { one: "one", other: "%{count} many" },
                                              greet: "Hi %{name}"
                                            }
                                          }
                                        }
                                      })

      I18n.with_locale(:en) do
        assert_equal "Close", I18n.t(key)
        assert_equal "Close", RecordingStudioAI.t(key)
        assert_equal "Close", RecordingStudioAI.t(key, default: "Ignored when present")
      end

      I18n.with_locale(:de) do
        assert_equal "Close", RecordingStudioAI.t(key),
                     "missing active locale uses loaded English"
        assert_match(/translation missing/i, I18n.t(key))

        assert_parity(missing)
        assert_parity(missing, default: "D")
        assert_raise_parity(missing, raise: true)

        I18n.backend.store_translations(:de, {
                                          recording_studio: { ai: { retained_responses: { close: "DE Fermer" } } }
                                        })
        assert_equal "DE Fermer", RecordingStudioAI.t(key)
        assert_equal I18n.t(key), RecordingStudioAI.t(key),
                     "no English fallback when the active locale has the key"

        assert_parity("recording_studio.ai.retained_responses.nil_value")
        assert_equal "", RecordingStudioAI.t("recording_studio.ai.retained_responses.empty_value")
        assert_match(/translation missing/i, I18n.t("recording_studio.ai.retained_responses.empty_value"))

        assert_equal(
          I18n.t("recording_studio.ai.retained_responses.nest", locale: :en),
          RecordingStudioAI.t("recording_studio.ai.retained_responses.nest")
        )
        assert_equal(
          I18n.t("recording_studio.ai.retained_responses.items", locale: :en, count: 1),
          RecordingStudioAI.t("recording_studio.ai.retained_responses.items", count: 1)
        )
        assert_equal(
          I18n.t("recording_studio.ai.retained_responses.greet", locale: :en, name: "M"),
          RecordingStudioAI.t("recording_studio.ai.retained_responses.greet", name: "M")
        )

        assert_equal "DE Fermer", RecordingStudioAI.t(:"recording_studio.ai.retained_responses.close")
        assert_equal(
          ["DE Fermer", "Saved reply"],
          RecordingStudioAI.t(%w[
                                recording_studio.ai.retained_responses.close
                                recording_studio.ai.retained_responses.page_title
                              ])
        )
        assert_equal "DE Fermer", RecordingStudioAI.t(:close, scope: "recording_studio.ai.retained_responses")

        assert_equal(
          "Saved reply",
          RecordingStudioAI.t(:page_title, scope: "recording_studio.ai.retained_responses"),
          "scope: gem key missing in :de must fall back to English"
        )

        html = RecordingStudioAI.t("recording_studio.ai.retained_responses.html_key_html")
        assert_equal "<i>g</i>", html
        assert_predicate html, :html_safe?

        assert_equal "D", RecordingStudioAI.t(missing, default: "D")

        I18n.backend.store_translations(:en, {
                                          recording_studio: {
                                            ai: { retained_responses: { missing_key_for_parity: "EN" } }
                                          }
                                        })
        assert_equal "EN", RecordingStudioAI.t(missing, default: "D")

        error = assert_raises(I18n::MissingTranslationData) do
          RecordingStudioAI.t("recording_studio.ai.retained_responses.totally_absent", raise: true)
        end
        assert_match(/Translation missing: de\.recording_studio/, error.message)

        assert_equal "Close", RecordingStudioAI.t(key, locale: :en)
      end
    end
  end

  test "fallback order prefers loaded english then caller default over shipped table" do
    I18nBackendIsolation.with_snapshot do
      key = "recording_studio.ai.retained_responses.close"

      write_loaded_translation!(:en, key, "HOST EN Close")
      I18n.with_locale(:de) do
        refute I18n.exists?(key, :de)
        assert_equal "HOST EN Close", RecordingStudioAI.t(key),
                     "host :en override must win over the gem-shipped table"
      end

      delete_loaded_translation!(:en, key)
      delete_loaded_translation!(:fr, key)
      %i[en fr de].each do |locale|
        I18n.with_locale(locale) do
          assert_equal "CALLER", RecordingStudioAI.t(key, default: "CALLER"),
                       "caller default: must come before the gem-shipped table in #{locale}"
        end
      end
    end
  end

  test "html gem keys escape unsafe interpolation like view t" do
    I18nBackendIsolation.with_snapshot do
      I18n.t("recording_studio.ai.retained_responses.close")
      I18n.backend.store_translations(:en, {
                                        recording_studio: {
                                          ai: {
                                            probe: {
                                              hi_html: "<b>Hi %{name}</b>",
                                              greet: "Hi %{name}",
                                              items_html: {
                                                one: "<i>1 x</i>",
                                                other: "<i>%{count} xs</i>"
                                              }
                                            }
                                          }
                                        }
                                      })
      view = ActionController::Base.helpers

      I18n.with_locale(:en) do
        value = RecordingStudioAI.t("recording_studio.ai.probe.hi_html", name: "<script>")
        assert_equal "<b>Hi &lt;script&gt;</b>", value
        assert_predicate value, :html_safe?
        assert_equal view.t("recording_studio.ai.probe.hi_html", name: "<script>"), value

        plain = RecordingStudioAI.t("recording_studio.ai.probe.greet", name: "<s>")
        assert_equal "Hi <s>", plain
        refute_predicate plain, :html_safe?
        assert_equal view.t("recording_studio.ai.probe.greet", name: "<s>"), plain

        safe_arg = "<u>ok</u>".html_safe
        with_safe = RecordingStudioAI.t("recording_studio.ai.probe.hi_html", name: safe_arg)
        assert_equal "<b>Hi <u>ok</u></b>", with_safe
        assert_equal view.t("recording_studio.ai.probe.hi_html", name: safe_arg), with_safe

        plural = RecordingStudioAI.t("recording_studio.ai.probe.items_html", count: 2)
        assert_equal "<i>2 xs</i>", plural
        assert_predicate plural, :html_safe?
        assert_equal view.t("recording_studio.ai.probe.items_html", count: 2), plural

        singular = RecordingStudioAI.t("recording_studio.ai.probe.items_html", count: 1)
        assert_equal "<i>1 x</i>", singular
        assert_predicate singular, :html_safe?
        assert_equal view.t("recording_studio.ai.probe.items_html", count: 1), singular

        missing_html = "recording_studio.ai.probe.missing_key_html"
        reserved = RecordingStudioAI.t(missing_html, default: "<b>ok</b>")
        assert_equal "<b>ok</b>", reserved
        refute_predicate reserved, :html_safe?
        assert_equal view.t(missing_html, default: "<b>ok</b>"), reserved
      end
    end
  end

  test "shipped english table is present after first load" do
    table = RecordingStudioAI::Translation.shipped_english
    refute_nil table
    refute_empty table
    assert_equal "Close", table.fetch("recording_studio.ai.retained_responses.close")
  end

  test "shipped english table becomes a new object after reload reset" do
    before = RecordingStudioAI::Translation.shipped_english
    RecordingStudioAI::Translation.reset_shipped_english!
    after = RecordingStudioAI::Translation.shipped_english

    refute_same before, after
    assert_equal before, after
    assert_predicate after, :frozen?
  end

  test "missing en.yml yields empty shipped english table" do
    RecordingStudioAI::Translation.reset_shipped_english!
    RecordingStudioAI::Translation.stub(:shipped_english_path, "/nonexistent/en.yml") do
      table = RecordingStudioAI::Translation.shipped_english
      assert_equal({}, table)
      assert_predicate table, :frozen?
    end
  ensure
    RecordingStudioAI::Translation.reset_shipped_english!
  end

  test "lazy keys pass through like I18n.t" do
    I18n.with_locale(:en) do
      assert_equal I18n.t(".lazy_key_without_scope"), RecordingStudioAI.t(".lazy_key_without_scope")
    end
  end

  test "nil key does not raise" do
    assert_nil RecordingStudioAI.t(nil)
  end

  test "global I18n config snapshot is unchanged by RecordingStudioAI.t" do
    before = i18n_config_snapshot

    RecordingStudioAI.t("recording_studio.ai.retained_responses.close")
    I18n.with_locale(:de) do
      RecordingStudioAI.t("recording_studio.ai.retained_responses.close")
      RecordingStudioAI.t("not_a_gem_key")
    end

    assert_equal before, i18n_config_snapshot
  end

  test "copy helper delegates to translation with prefix" do
    I18n.with_locale(:de) do
      assert_equal "Close", RecordingStudioAI::Copy.t("retained_responses.close")
      assert_equal "Recording Studio AI", RecordingStudioAI::Copy.t("admin.section.title")
    end
  end

  test "other recording_studio keys are not treated as this gem" do
    I18n.with_locale(:de) do
      # Sibling-gem keys are not in this gem's shipped table; pass through to I18n.t.
      key = "recording_studio.other_gem.missing_for_ai_fallback"
      refute I18n.exists?(key, :de)
      refute RecordingStudioAI::Translation.shipped_english.key?(key)
      assert_equal "PASS", RecordingStudioAI.t(key, default: "PASS")
      assert_match(/translation missing/i, RecordingStudioAI.t(key).to_s)
    end
  end

  private

  def assert_parity(key, **options)
    expected = I18n.t(key, **options)
    actual = RecordingStudioAI.t(key, **options)
    assert_equal expected, actual, "parity failed for #{key.inspect} options=#{options.inspect}"
    return unless actual.is_a?(String) && key.to_s.match?(/(\b|_|\.)html\z/)
    return unless expected.respond_to?(:html_safe?) && actual.respond_to?(:html_safe?)

    assert_equal expected.html_safe?, actual.html_safe?
  end

  def assert_raise_parity(key, **options)
    i18n_error = assert_raises(I18n::MissingTranslationData) { I18n.t(key, **options) }
    rs_error = assert_raises(I18n::MissingTranslationData) { RecordingStudioAI.t(key, **options) }
    assert_equal i18n_error.message, rs_error.message
  end

  def i18n_config_snapshot
    {
      load_path: I18n.load_path.map { |path| File.expand_path(path) },
      available_locales: Array(I18n.available_locales).map(&:to_sym).sort,
      exception_handler: I18n.exception_handler,
      enforce_available_locales: I18n.enforce_available_locales,
      fallbacks_class: (I18n.fallbacks.class.name if I18n.respond_to?(:fallbacks)),
      fallbacks_de: (I18n.fallbacks[:de].dup if I18n.respond_to?(:fallbacks)),
      fallbacks_fr: (I18n.fallbacks[:fr].dup if I18n.respond_to?(:fallbacks)),
      fallbacks_en: (I18n.fallbacks[:en].dup if I18n.respond_to?(:fallbacks))
    }
  end

  def flatten_locale_keys(node, prefix)
    case node
    when Hash
      node.each_with_object({}) do |(key, value), result|
        result.merge!(flatten_locale_keys(value, prefix + [key.to_s]))
      end
    else
      { prefix.join(".") => node }
    end
  end

  def delete_loaded_translation!(locale, full_key)
    mutate_loaded_translation!(locale, full_key) { |node, leaf| node.delete(leaf) }
  end

  def write_loaded_translation!(locale, full_key, value)
    mutate_loaded_translation!(locale, full_key) { |node, leaf| node[leaf] = value }
  end

  # rubocop:disable Metrics/CyclomaticComplexity -- backend hash walk matches RecordingStudio
  def mutate_loaded_translation!(locale, full_key)
    I18n.exists?(full_key, locale) # ensure translations are loaded
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
    yield node, leaf if node.is_a?(Hash)
  end
  # rubocop:enable Metrics/CyclomaticComplexity

  def ensure_engine_locale_loaded!
    EngineLocale.ensure_loaded!
  end
end
