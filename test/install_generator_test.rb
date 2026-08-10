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
      assert_includes initializer, "config.retain_responses = false"
      assert_includes initializer, "config.response_retention_period = 7.days"
      assert_includes initializer, "config.maximum_retained_response_size = 1.megabyte"
      assert_includes initializer, "config.maximum_attempts = 3"
      assert_includes initializer, "config.maximum_retries_per_candidate = 1"
      assert_includes initializer, "config.maximum_provider_fallbacks = 1"
      assert_includes initializer, "config.maximum_custom_tool_rounds = 5"
      assert_includes initializer, "config.request_timeout = 120"
    end
  end

  def test_install_guide_is_foundation_only
    install_guide = File.read(INSTALL_TEMPLATE_PATH)

    assert_includes install_guide, "Confirm Recording Studio is configured"
    assert_includes install_guide, "does not install migrations"
    assert_includes install_guide, "no provider SDK is required"
    refute_includes install_guide, "recording_studio_ai:migrations"
  end
end
