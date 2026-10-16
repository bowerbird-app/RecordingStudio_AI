# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

# Host provider credentials must not leak into gem unit tests. Contract tests
# expect the default configuration to resolve as unimplemented. The opt-in live
# Agents test stashes the key only when that test is explicitly enabled.
module RecordingStudioAI
  module Test
    LIVE_OPENAI_API_KEY = ENV["RECORDING_STUDIO_AI_LIVE_AGENTS"] == "1" ? ENV.fetch("OPENAI_API_KEY", nil) : nil
  end
end
ENV.delete("OPENAI_API_KEY")
ENV.delete("GEMINI_API_KEY")
ENV.delete("TYPESAFE_API_KEY")
ENV.delete("TYPESAFE_API_KEY")

require_relative "simplecov_helper"
require "minitest/autorun"
begin
  require "minitest/mock"
rescue LoadError
  # Minitest 6 extracted Object#stub into minitest-mock. Unit tests install it
  # via the root Gemfile; the dummy app bundle may not. Soft-load so dummy
  # tests that require this helper still boot.
end
require "rails"
require "i18n"
require "yaml"
require "recording_studio_ai"

# Do not append gem locales to I18n.load_path here. Rails engines already put
# config/locales on the load path when the dummy boots; an explicit append can
# re-order files so gem English overrides the host. Unit tests (no Rails app)
# seed the backend from en.yml without touching the load path, and mirror the
# engine boot registration so RecordingStudio.t can fall back to this gem's
# English when keys are deleted from the loaded backend. The dummy integration
# registration assertion must still fail on its own if the engine initializer
# body is removed — do not call that initializer block from tests.
I18n.available_locales = Array(I18n.available_locales) | %i[en]
I18n.default_locale = :en
gem_english_path = File.expand_path("../config/locales/en.yml", __dir__)
gem_english = YAML.safe_load_file(gem_english_path, aliases: true).fetch("en")
I18n.backend.store_translations(:en, gem_english)
RecordingStudio::Translation.register_shipped_english(gem_english_path)

require_relative "support/configuration_isolation"
require_relative "support/persistence"
require_relative "support/persistence_case"
