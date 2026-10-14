# frozen_string_literal: true

# Shared helper for gem unit tests that boot without Rails auto-loading
# engine locales. Prefer load_translations over bare reload! so in-memory
# store_translations from sibling tests stay put when possible; when the gem
# English key is absent (after a mutating test), force a reload from load_path.
module EngineLocale
  module_function

  PROBE_KEY = "recording_studio.ai.retained_responses.close"

  def ensure_loaded!(root: File.expand_path("../..", __dir__))
    locale_path = File.expand_path("config/locales/en.yml", root)
    expanded = I18n.load_path.map { |path| File.expand_path(path) }
    I18n.load_path << locale_path unless expanded.include?(locale_path)

    return if I18n.exists?(PROBE_KEY, :en)

    I18n.backend.load_translations
    return if I18n.exists?(PROBE_KEY, :en)

    # Last resort after a prior I18n.reload! left the backend empty.
    I18n.reload!
  end
end
