# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "tmpdir"
require "generators/recording_studio_ai/install/install_generator"

class InstallGeneratorTest < Minitest::Test
  INSTALL_TEMPLATE_PATH = File.expand_path(
    "../lib/generators/recording_studio_ai/install/templates/INSTALL.md",
    __dir__
  )

  def build_generator(destination_root, options = {})
    RecordingStudioAI::Generators::InstallGenerator.new(
      [],
      options,
      destination_root: destination_root
    )
  end

  def test_mount_engine_uses_default_mount_path
    routes = []
    generator = build_generator("/tmp")

    generator.stub(:route, ->(value) { routes << value }) do
      generator.mount_engine
    end

    assert_equal ['mount RecordingStudioAI::Engine, at: "/recording_studio_ai"'], routes
  end

  def test_mount_engine_uses_configured_mount_path
    routes = []
    generator = build_generator("/tmp", mount_path: "/addons/ai")

    generator.stub(:route, ->(value) { routes << value }) do
      generator.mount_engine
    end

    assert_equal ['mount RecordingStudioAI::Engine, at: "/addons/ai"'], routes
  end

  def test_copy_initializer_creates_recording_studio_ai_configuration
    Dir.mktmpdir do |directory|
      build_generator(directory).copy_initializer
      initializer = File.read(File.join(directory, "config/initializers/recording_studio_ai.rb"))

      assert_includes initializer, "RecordingStudioAI.configure"
      assert_includes initializer, "OPENAI_API_KEY"
      assert_includes initializer, "openai, :api_key"
      assert_includes initializer, "GEMINI_API_KEY"
      assert_includes initializer, "gemini, :api_key"
      assert_includes initializer, "config.openai_client"
      assert_includes initializer, "config.gemini_client"
      assert_includes initializer, "config.default_profile = :medium"
      assert_includes initializer, "config.profiles = {"
      assert_includes initializer, "gpt-5-mini"
      assert_includes initializer, "gpt-5-pro"
      assert_includes initializer, "config.cost_catalogs = {}"
      assert_includes initializer, "config.batch_synchronization_interval = 1.minute"
      assert_includes initializer, "config.allowed_provider_overrides"
      assert_includes initializer, "config.retain_responses = false"
      assert_includes initializer, "config.response_retention_period = 7.days"
      assert_includes initializer, "config.maximum_retained_response_size = 1.megabyte"
      assert_includes initializer, "config.response_sanitizer = nil"
      assert_includes initializer, "config.instrumentation_enabled = true"
      assert_includes initializer, 'config.notification_namespace = "recording_studio_ai"'
      assert_includes initializer, "config.admin_warning_thresholds"
      assert_includes initializer, "config.maximum_attempts = 3"
      assert_includes initializer, "config.maximum_attachment_count = 10"
      assert_includes initializer, "config.maximum_attachment_bytes = 20.megabytes"
      assert_includes initializer, "config.maximum_attachment_total_bytes = 50.megabytes"
      assert_includes initializer, "config.allowed_attachment_content_types"
      assert_includes initializer, "config.maximum_retries_per_candidate = 1"
      assert_includes initializer, "config.maximum_provider_fallbacks = 1"
      assert_includes initializer, "config.maximum_profile_fallbacks = 1"
      assert_includes initializer, "config.profile_fallbacks = {}"
      assert_includes initializer, "config.maximum_custom_tool_rounds = 5"
      assert_includes initializer, "config.custom_tool_timeout = 30"
      assert_includes initializer, "config.maximum_custom_tool_result_size = 256.kilobytes"
      assert_includes initializer, "config.custom_tool_confirmation_handler = ->(**) { false }"
      assert_includes initializer, "config.total_execution_timeout = 300"
      assert_includes initializer, "config.request_timeout = 120"
      assert_includes initializer, "config.stream_idle_timeout = 30"
      assert_includes initializer, "config.authorization_handler"
      assert_includes initializer, "RecordingStudioAI::AccessibleAuthorization"
      assert_includes initializer, "config.admin_authenticate"
      assert_includes initializer, "config.attribution_validator"
    end
  end

  def test_install_guide_includes_v1_provider_migration_and_operations_steps
    install_guide = File.read(INSTALL_TEMPLATE_PATH)

    assert_includes install_guide, "Confirm Recording Studio is configured"
    assert_includes install_guide, "recording_studio_ai:install:migrations"
    assert_includes install_guide, "bin/rails db:migrate"
    assert_includes install_guide, "Configure at least one OpenAI or Gemini credential"
    assert_includes install_guide, "authorization handler"
    assert_includes install_guide, "AccessibleAuthorization"
    assert_includes install_guide, "admin_authenticate"
    assert_includes install_guide, "Active Record Encryption"
    assert_includes install_guide, "ResponseCleanupJob"
    assert_includes install_guide, "admin_visible_roots_resolver"
    assert_includes install_guide, "Recording Studio Admin's Accessible check"
    assert_includes install_guide, "provider-side retention"
    assert_includes install_guide, "db:rollback"
    refute_includes install_guide, "does not install migrations"
  end
end
