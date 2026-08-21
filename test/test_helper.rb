# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

# Host provider credentials must not leak into gem unit tests. Contract tests
# expect the default configuration to resolve as unimplemented.
ENV.delete("OPENAI_API_KEY")
ENV.delete("GEMINI_API_KEY")

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
require "recording_studio_ai"

require_relative "support/configuration_isolation"
require_relative "support/persistence"
require_relative "support/persistence_case"
