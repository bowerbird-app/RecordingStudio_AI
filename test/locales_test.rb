# frozen_string_literal: true

require "test_helper"
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

  test "gemspec does not depend on recording_studio_internationalization" do
    gemspec = File.read(File.expand_path("../recording_studio_ai.gemspec", __dir__))

    refute_includes gemspec, "recording_studio_internationalization"
  end

  private

  def engine_locales_dir
    File.expand_path("../config/locales", __dir__)
  end

  def locale_tree(path, locale)
    YAML.safe_load_file(path, aliases: true).fetch(locale)
  end

  def ensure_engine_locale_loaded!
    locale_path = File.expand_path(File.join(engine_locales_dir, "en.yml"))
    expanded = I18n.load_path.map { |path| File.expand_path(path) }
    return if expanded.include?(locale_path)

    I18n.load_path << locale_path
    I18n.backend.reload!
  end
end
