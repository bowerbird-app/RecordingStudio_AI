# frozen_string_literal: true

require "test_helper"
require_relative "support/engine_locale"
require "yaml"

class LocalesTest < ActiveSupport::TestCase
  RETAINED_RESPONSE_KEYS = {
    "close" => "Close",
    "page_title" => "Saved reply",
    "page_subtitle" => "What the model sent back.",
    "about_title" => "About this reply",
    "type" => "Type",
    "status" => "Status",
    "cut_short" => "Cut short",
    "size" => "Size",
    "expires" => "Expires",
    "content_type" => "Content type",
    "open_call" => "Open this call",
    "complete" => "Complete",
    "incomplete" => "Incomplete",
    "truncated" => "Truncated",
    "reply" => "Reply",
    "structured_reply" => "Structured reply",
    "provider_payload" => "Provider payload"
  }.freeze

  setup do
    ensure_engine_locale_loaded!
  end

  test "engine ships only english locale files" do
    files = Dir[File.join(engine_locales_dir, "*")].map { |path| File.basename(path) }

    assert_equal ["en.yml"], files.sort
  end

  test "rails i18n load path includes the gem english locale file" do
    locale_path = File.expand_path(File.join(engine_locales_dir, "en.yml"))

    assert_includes I18n.load_path.map { |path| File.expand_path(path) }, locale_path
  end

  test "english retained response keys resolve without missing translations" do
    I18n.with_locale(:en) do
      RETAINED_RESPONSE_KEYS.each do |key, english|
        full_key = "recording_studio.ai.retained_responses.#{key}"
        translation = I18n.t(full_key, default: nil)

        assert_equal english, translation, "#{full_key} should resolve to #{english.inspect}"
        assert_equal english, I18n.t(full_key, raise: true)
      end
    end
  end

  test "en.yml nests keys under recording_studio.ai" do
    tree = locale_tree(File.join(engine_locales_dir, "en.yml"), "en")
           .fetch("recording_studio")
           .fetch("ai")
           .fetch("retained_responses")

    assert_equal RETAINED_RESPONSE_KEYS, tree.transform_keys(&:to_s)
  end

  test "en.yml includes wave2 admin and common keys" do
    tree = locale_tree(File.join(engine_locales_dir, "en.yml"), "en")
           .fetch("recording_studio")
           .fetch("ai")

    assert tree.key?("admin")
    assert tree.key?("common")
    assert_equal "Recording Studio AI", tree.dig("admin", "section", "title")
    assert_equal "1st attempt", tree.dig("admin", "attempt_kinds", "primary")
    # Quoted in en.yml so YAML 1.1 does not coerce them to boolean keys.
    assert_equal "Yes", tree.fetch("common").fetch("yes")
    assert_equal "No", tree.fetch("common").fetch("no")
  end

  test "gemspec does not depend on recording_studio_internationalization" do
    gemspec = File.read(File.expand_path("../recording_studio_ai.gemspec", __dir__))

    refute_includes gemspec, "recording_studio_internationalization"
  end

  test "lib ruby files do not append to i18n load path" do
    lib_files = Dir[File.expand_path("../lib/**/*.rb", __dir__)]

    assert_operator lib_files.length, :>=, 1

    lib_files.each do |path|
      source = File.read(path)

      refute_includes source, "i18n.load_path",
                      "#{path} must not touch config.i18n.load_path (Rails engines load config/locales automatically)"
      refute_includes source, "I18n.load_path",
                      "#{path} must not append to I18n.load_path (that re-adds gem English after host overrides)"
    end
  end

  test "copy helper prefixes recording_studio.ai and resolves from en.yml" do
    I18n.with_locale(:en) do
      assert_equal "Saved reply", RecordingStudioAI::Copy.t("retained_responses.page_title")
      assert_equal "AI Calls", RecordingStudioAI::Copy.t("admin.screens.ai_calls.title")
      # Must resolve from the locale file, not only via default: (yes/no are YAML-sensitive).
      assert_equal "Yes", RecordingStudioAI::Copy.t("common.yes")
      assert_equal "No", RecordingStudioAI::Copy.t("common.no")
      assert_equal "Yes", I18n.t("recording_studio.ai.common.yes", raise: true)
      assert_equal "No", I18n.t("recording_studio.ai.common.no", raise: true)
    end
  end

  test "missing locale falls back to gem english for retained response keys" do
    previous_locales = I18n.available_locales
    I18n.available_locales = (previous_locales + %i[en de]).uniq

    I18n.with_locale(:de) do
      RETAINED_RESPONSE_KEYS.each do |key, english|
        full_key = "recording_studio.ai.retained_responses.#{key}"
        refute I18n.exists?(full_key, :de)
        assert_equal english, RecordingStudio.t(full_key),
                     "#{full_key}: missing-locale fallback must match en.yml"
      end
    end
  ensure
    I18n.available_locales = previous_locales if previous_locales
  end

  test "RecordingStudio.t call sites only use this gem recording_studio.ai keys" do
    roots = [
      File.expand_path("../app", __dir__),
      File.expand_path("../lib", __dir__)
    ]
    files = roots.flat_map { |root| Dir[File.join(root, "**", "*.{rb,erb}")] }
    offenders = []

    files.each do |path|
      source = File.read(path)
      source.scan(/RecordingStudio\.t\(\s*["']([^"']+)["']/) do |match|
        key = match[0]
        next if key.include?('#{') # interpolated Copy.t → "#{PREFIX}.#{key}"
        next if key.start_with?("recording_studio.ai.")

        offenders << "#{path}: RecordingStudio.t(#{key.inspect})"
      end
    end

    assert_empty offenders,
                 "only recording_studio.ai.* keys may use RecordingStudio.t; " \
                 "host or other-namespace keys stay on I18n.t with main's default:; " \
                 "found: #{offenders.join(', ')}"
  end

  test "every gem translation call site key exists in en.yml and has no default" do
    shipped = shipped_english_keys
    roots = [
      File.expand_path("../app", __dir__),
      File.expand_path("../lib", __dir__)
    ]
    files = roots.flat_map { |root| Dir[File.join(root, "**", "*.{rb,erb}")] }
    refute_empty files

    offenders = []
    unknown_keys = []

    files.each do |path|
      source = File.read(path)
      each_translation_call_args(source) do |method_name, args|
        keys = extract_recording_studio_ai_keys(method_name, args)
        next if keys.empty? && !args.match?(/recording_studio\.ai/) && !method_name.include?("Copy.t")

        keys.each do |key|
          next if key.include?('#{') # interpolated dynamic keys

          next if shipped.key?(key)
          # Plural parents (one/other) are stored as key.one / key.other in the flat map.
          next if shipped.keys.any? { |shipped_key| shipped_key.start_with?("#{key}.") }

          unknown_keys << "#{path}: #{key}"
        end

        next unless args.match?(/\bdefault:\s*/)

        offenders << "#{path}: #{method_name}(... default: ...) args=#{args.gsub(/\s+/, ' ').strip[0, 120]}"
      end
    end

    assert_empty unknown_keys,
                 "RecordingStudio.t / Copy.t keys must exist in en.yml; unknown: #{unknown_keys.join(', ')}"
    assert_empty offenders,
                 "gem recording_studio.ai lookups must not pass default:; found: #{offenders.join(', ')}"
  end

  test "scanner catches EMPTY_LABEL single-quoted multi-line I18n.translate Array and paren-less defaults" do
    samples = {
      empty_label: <<~RUBY,
        RecordingStudio.t("recording_studio.ai.retained_responses.close", default: EMPTY_LABEL)
      RUBY
      single_quoted: <<~RUBY,
        RecordingStudio.t('recording_studio.ai.retained_responses.page_title', default: 'Saved reply')
      RUBY
      multi_line: <<~RUBY,
        RecordingStudio.t(
          "recording_studio.ai.retained_responses.page_subtitle",
          default: "What the model sent back."
        )
      RUBY
      i18n_translate: <<~RUBY,
        I18n.translate("recording_studio.ai.retained_responses.close", default: "Close")
      RUBY
      array_default: <<~RUBY,
        I18n.t("recording_studio.ai.retained_responses.reply", default: ["Reply", "Fallback"])
      RUBY
      bare_t: <<~RUBY,
        t("recording_studio.ai.retained_responses.type", default: "Type")
      RUBY
      paren_less: <<~RUBY,
        RecordingStudio.t "recording_studio.ai.retained_responses.close", default: "Close"
      RUBY
      copy_default: <<~RUBY
        Copy.t("admin.section.title", default: "Recording Studio AI")
      RUBY
    }

    samples.each do |name, source|
      found = false
      each_translation_call_args(source) do |_method_name, args|
        found = true if args.match?(/\bdefault:\s*/)
      end
      assert found, "scanner must catch #{name} default: form"
    end
  end

  private

  def engine_locales_dir
    File.expand_path("../config/locales", __dir__)
  end

  def locale_tree(path, locale)
    YAML.safe_load_file(path, aliases: true).fetch(locale)
  end

  def shipped_english_keys
    tree = locale_tree(File.join(engine_locales_dir, "en.yml"), "en")
           .fetch("recording_studio").fetch("ai")
    flatten_locale_keys(tree, %w[recording_studio ai])
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

  def each_translation_call_args(source)
    pattern = /
      (?:RecordingStudio\.t|Copy\.t|I18n\.(?:t|translate)|(?<![\w.:])t)
      (?:
        \s*\(
        |
        \s+(?=["'])
      )
    /mx
    offset = 0
    while (match = pattern.match(source, offset))
      method_name = match[0].sub(/\s*[(]\z/, "").sub(/\s+\z/, "")
      args_start = match.end(0)
      if match[0].include?("(")
        args, args_end = read_balanced_args(source, args_start)
      else
        args, args_end = read_paren_less_args(source, args_start)
      end
      yield method_name, args
      offset = args_end
    end
  end

  # Scanner helpers mirror RecordingStudio locales_test (balanced / paren-less args).
  # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
  def read_paren_less_args(source, start_index)
    index = start_index
    in_single = false
    in_double = false
    escape = false

    while index < source.length
      char = source[index]
      break if !in_single && !in_double && %W[\n ;].include?(char)

      if escape
        escape = false
      elsif char == "\\" && (in_single || in_double)
        escape = true
      elsif char == "'" && !in_double
        in_single = !in_single
      elsif char == '"' && !in_single
        in_double = !in_double
      end
      index += 1
    end

    [source[start_index...index], index]
  end

  def read_balanced_args(source, start_index)
    depth = 1
    index = start_index
    in_single = false
    in_double = false
    escape = false

    while index < source.length && depth.positive?
      char = source[index]

      if escape
        escape = false
      elsif char == "\\" && (in_single || in_double)
        escape = true
      elsif char == "'" && !in_double
        in_single = !in_single
      elsif char == '"' && !in_single
        in_double = !in_double
      elsif !in_single && !in_double
        case char
        when "(" then depth += 1
        when ")" then depth -= 1
        end
      end

      index += 1
    end

    [source[start_index...(index - 1)], index]
  end
  # rubocop:enable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

  def extract_recording_studio_ai_keys(method_name, args)
    keys = []
    args.scan(/["'](recording_studio\.ai\.[^"']+)["']/) { |match| keys << match[0] }
    if (match = args.match(/%w\[([^\]]+)\]/))
      match[1].split.each do |token|
        keys << token if token.start_with?("recording_studio.ai.")
      end
    end
    if method_name.include?("Copy.t")
      args.scan(/["']((?:admin|common|retained_responses)\.[^"']+)["']/) do |match|
        keys << "recording_studio.ai.#{match[0]}"
      end
    end
    keys
  end

  def ensure_engine_locale_loaded!
    EngineLocale.ensure_loaded!
  end
end
