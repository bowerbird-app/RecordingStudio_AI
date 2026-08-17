# frozen_string_literal: true

require "test_helper"

class RecordingStudioAITest < Minitest::Test
  def test_version_matches_initial_addon_release
    assert_equal "0.2.0", RecordingStudioAI::VERSION
  end

  def test_runtime_dependencies_are_declared
    specification = Gem::Specification.load(File.expand_path("../recording_studio_ai.gemspec", __dir__))
    dependencies = specification.runtime_dependencies.to_h { |dependency| [dependency.name, dependency.requirement] }

    assert_equal %w[csv flat_pack json_schemer openai rails recording_studio], dependencies.keys.sort
  end

  def test_phase_six_ships_concrete_providers_without_example_surfaces
    root = File.expand_path("..", __dir__)

    migration_files = Dir[File.join(root, "db/migrate/*.rb")]

    assert_equal 7, migration_files.size
    assert migration_files.any? { |file| file.include?("create_recording_studio_ai_persistence_tables") }
    assert migration_files.any? { |file| file.include?("harden_recording_studio_ai_persistence") }
    assert migration_files.any? { |file| file.include?("enforce_recording_studio_ai_history_integrity") }
    assert migration_files.any? { |file| file.include?("add_prompt_attribution_to_recording_studio_ai_runs") }
    assert File.exist?(File.join(root, "lib/recording_studio_ai/providers/base.rb"))
    assert File.exist?(File.join(root, "lib/recording_studio_ai/providers/openai.rb"))
    assert File.exist?(File.join(root, "lib/recording_studio_ai/providers/gemini.rb"))
    refute File.exist?(File.join(root, "lib/recording_studio_ai/services/example_service.rb"))
    refute File.exist?(File.join(root, "app/controllers/recording_studio_ai/home_controller.rb"))
  end

  def test_dummy_host_mounts_addon_and_preserves_recording_studio
    routes = File.read(File.expand_path("dummy/config/routes.rb", __dir__))
    recording_studio_initializer =
      File.read(File.expand_path("dummy/config/initializers/recording_studio.rb", __dir__))

    assert_includes routes, 'mount RecordingStudioAI::Engine, at: "/recording_studio_ai"'
    assert_includes routes, 'mount RecordingStudio::Engine, at: "/recording_studio"'
    assert_includes recording_studio_initializer, "config.require_recordable_declarations = true"
  end

  def test_dummy_home_describes_foundation_scope
    home = File.read(File.expand_path("dummy/app/views/home/index.html.erb", __dir__))

    assert_includes home, 'title: "Recording Studio AI"'
    assert_includes home, "OpenAI or Gemini credentials can be supplied without selecting a provider."
    assert_includes home, "Addon migrations install six execution infrastructure tables."
    assert_includes home, "Synchronous generation resolves OpenAI or Gemini"
  end

  def test_persistence_models_are_non_recordable_infrastructure
    refute File.exist?(File.expand_path("../app/models/recording_studio_ai/home.rb", __dir__))
    assert File.exist?(File.expand_path("../app/models/recording_studio_ai/run.rb", __dir__))
    assert File.exist?(File.expand_path("../app/models/recording_studio_ai/attempt.rb", __dir__))
    assert File.exist?(File.expand_path("../app/models/recording_studio_ai/custom_tool_invocation.rb", __dir__))
    assert File.exist?(File.expand_path("../app/models/recording_studio_ai/batch.rb", __dir__))
    assert File.exist?(File.expand_path("../app/models/recording_studio_ai/batch_item.rb", __dir__))
    assert File.exist?(File.expand_path("../app/models/recording_studio_ai/response.rb", __dir__))
  end
end
