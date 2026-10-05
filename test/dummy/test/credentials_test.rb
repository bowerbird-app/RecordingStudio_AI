# frozen_string_literal: true

require "test_helper"

class CredentialsTest < ActiveSupport::TestCase
  test "dummy credentials expose shared keys when the master key is available" do
    skip "Set RAILS_MASTER_KEY or test/dummy/config/master.key to the shared dummy key" unless master_key_available?

    credentials = Rails.application.credentials
    assert credentials.secret_key_base.present?
    assert_equal "dev_placeholder", credentials.dig(:openai, :api_key)
    assert_equal "dev_placeholder", credentials.dig(:openai, :webhook_secret)
    assert_equal "dev_placeholder", credentials.dig(:gemini, :api_key)
    assert_equal "dev_placeholder", credentials.dig(:typesafe, :api_key)
    assert_equal "dev_placeholder", credentials.dig(:smtp, :user_name)
    assert_equal "dev_placeholder", credentials.dig(:smtp, :password)
    assert_equal "dev_placeholder", credentials.dig(:aws, :access_key_id)
    assert_equal "dev_placeholder", credentials.dig(:aws, :secret_access_key)
    assert_equal "dev_placeholder", credentials.dig(:gem_template, :api_key)
    assert_equal "dev_placeholder", credentials.dig(:active_record_encryption, :primary_key)
    assert_equal "dev_placeholder", credentials.dig(:active_record_encryption, :deterministic_key)
    assert_equal "dev_placeholder", credentials.dig(:active_record_encryption, :key_derivation_salt)
  end

  private

  def master_key_available?
    ENV["RAILS_MASTER_KEY"].to_s.strip.present? || File.exist?(Rails.root.join("config/master.key"))
  end
end
