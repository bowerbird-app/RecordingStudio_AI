# frozen_string_literal: true

require "test_helper"
require "yaml"
require "active_support/encrypted_file"

class DummyCredentialsTest < Minitest::Test
  PLACEHOLDER = "dev_placeholder"

  def test_only_dummy_credentials_file_is_committed
    tracked = Dir.chdir(File.expand_path("..", __dir__)) do
      `git ls-files -- '*.yml.enc'`.split("\n").reject(&:empty?)
    end

    assert_equal ["test/dummy/config/credentials.yml.enc"], tracked
  end

  def test_encrypted_credentials_file_is_present
    path = dummy_credentials_path
    assert File.exist?(path), "Expected #{path} so gems reuse the shared dummy credentials"
    assert File.size(path).positive?
  end

  def test_master_key_is_gitignored_and_untracked
    gitignore = File.read(File.expand_path("../.gitignore", __dir__))
    assert_includes gitignore, "test/dummy/config/master.key"
    assert_includes gitignore, "config/master.key"

    tracked = Dir.chdir(File.expand_path("..", __dir__)) do
      `git ls-files -- config/master.key test/dummy/config/master.key`.strip
    end
    assert_equal "", tracked, "master.key must not be committed"
  end

  def test_dummy_credentials_decrypt_when_master_key_is_available
    skip "Set RAILS_MASTER_KEY or test/dummy/config/master.key to the shared dummy key" unless master_key_available?

    parsed = YAML.safe_load(
      ActiveSupport::EncryptedFile.new(
        content_path: dummy_credentials_path,
        key_path: dummy_master_key_path,
        env_key: "RAILS_MASTER_KEY",
        raise_if_missing_key: true
      ).read
    )

    assert_operator parsed.fetch("secret_key_base").to_s.length, :>=, 64
    assert_equal PLACEHOLDER, parsed.dig("openai", "api_key")
    assert_equal PLACEHOLDER, parsed.dig("openai", "webhook_secret")
    assert_equal PLACEHOLDER, parsed.dig("gemini", "api_key")
    assert_equal PLACEHOLDER, parsed.dig("typesafe", "api_key")
    assert_equal PLACEHOLDER, parsed.dig("smtp", "user_name")
    assert_equal PLACEHOLDER, parsed.dig("smtp", "password")
    assert_equal PLACEHOLDER, parsed.dig("aws", "access_key_id")
    assert_equal PLACEHOLDER, parsed.dig("aws", "secret_access_key")
    assert_equal PLACEHOLDER, parsed.dig("gem_template", "api_key")
    assert_equal PLACEHOLDER, parsed.dig("active_record_encryption", "primary_key")
    assert_equal PLACEHOLDER, parsed.dig("active_record_encryption", "deterministic_key")
    assert_equal PLACEHOLDER, parsed.dig("active_record_encryption", "key_derivation_salt")
  end

  private

  def dummy_credentials_path
    File.expand_path("../test/dummy/config/credentials.yml.enc", __dir__)
  end

  def dummy_master_key_path
    File.expand_path("../test/dummy/config/master.key", __dir__)
  end

  def master_key_available?
    ENV["RAILS_MASTER_KEY"].to_s.strip.present? || File.exist?(dummy_master_key_path)
  end
end
