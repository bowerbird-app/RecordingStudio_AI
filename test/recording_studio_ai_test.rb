# frozen_string_literal: true

require "test_helper"

class RecordingStudioAITest < Minitest::Test
  def test_version_matches_initial_addon_release
    assert_equal "0.1.0", RecordingStudioAI::VERSION
  end

  def test_runtime_dependencies_are_declared
    specification = Gem::Specification.load(File.expand_path("../recording_studio_ai.gemspec", __dir__))
    dependencies = specification.runtime_dependencies.to_h { |dependency| [dependency.name, dependency.requirement] }

    assert_equal %w[rails recording_studio], dependencies.keys.sort
  end

  def test_phase_one_ships_no_addon_database_or_example_surfaces
    root = File.expand_path("..", __dir__)

    assert_empty Dir[File.join(root, "db/migrate/*.rb")]
    assert_empty Dir[File.join(root, "lib/generators/recording_studio_ai/migrations/**/*.rb")]
    assert_empty Dir[File.join(root, "lib/recording_studio_ai/adapters/**/*.rb")]
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
    assert_includes home, "No addon migrations or database tables are installed."
    assert_includes home, "Generation behavior is intentionally deferred"
  end
end
