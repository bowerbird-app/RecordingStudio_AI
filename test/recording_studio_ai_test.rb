# frozen_string_literal: true

require "test_helper"

class RecordingStudioAITest < Minitest::Test
  def test_version_matches_initial_addon_release
    assert_equal "0.3.1", RecordingStudioAI::VERSION
  end

  def test_admin_catalog_uses_public_rsa_registration
    admin_root = File.expand_path("../lib/recording_studio_ai/admin", __dir__)
    entry = File.read(File.expand_path("../lib/recording_studio_ai/admin_screens.rb", __dir__))
    manifest = File.read(File.join(admin_root, "manifest.rb"))

    assert_includes entry, 'require_relative "admin/manifest"'
    assert_includes manifest, "def self.register!"
    assert_includes manifest, "def self.load!"
    assert_includes manifest, "RecordingStudioAdmin.register_widget"
    assert_includes manifest, "RecordingStudioAdmin.register_screen"
    assert_includes manifest, "RecordingStudioAdmin.register_section"
    refute_includes File.read(File.join(admin_root, "section.rb")), "class_eval"
    refute_includes manifest, "prepend"
  end

  def test_orchestrator_extracts_named_collaborators
    root = File.expand_path("../lib/recording_studio_ai/orchestration", __dir__)

    %w[
      planner.rb persistence.rb attempt_runner.rb plan_executor.rb
      stream_session.rb custom_tools.rb response_builder.rb
    ].each do |file|
      assert File.exist?(File.join(root, file)), "missing orchestration/#{file}"
    end
    assert_equal RecordingStudioAI::Orchestration::CancellationState,
                 RecordingStudioAI::Orchestrator::CancellationState
    assert_operator File.foreach(File.expand_path("../lib/recording_studio_ai/orchestrator.rb", __dir__)).count, :<, 120
  end

  def test_runtime_dependencies_are_declared
    specification = Gem::Specification.load(File.expand_path("../recording_studio_ai.gemspec", __dir__))
    dependencies = specification.runtime_dependencies.to_h { |dependency| [dependency.name, dependency.requirement] }

    assert_equal %w[csv flat_pack json_schemer openai rails recording_studio], dependencies.keys.sort
    assert_equal "~> 4.2", dependencies.fetch("recording_studio").to_s
    refute_includes dependencies.keys, "recording_studio_accessible"
  end

  def test_phase_six_ships_concrete_providers_without_example_surfaces
    root = File.expand_path("..", __dir__)

    migration_files = Dir[File.join(root, "db/migrate/*.rb")]

    assert_equal 8, migration_files.size
    assert migration_files.any? { |file| file.include?("create_recording_studio_ai_persistence_tables") }
    assert migration_files.any? { |file| file.include?("harden_recording_studio_ai_persistence") }
    assert migration_files.any? { |file| file.include?("enforce_recording_studio_ai_history_integrity") }
    assert migration_files.any? { |file| file.include?("add_prompt_attribution_to_recording_studio_ai_runs") }
    assert migration_files.any? do |file|
      file.include?("remove_prompt_namespace_and_short_name_from_recording_studio_ai_runs")
    end
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
    assert_includes routes, 'mount RecordingStudioAccessible::Engine, at: "/recording_studio_accessible"'
    assert_includes recording_studio_initializer, "config.require_recordable_declarations = true"
  end

  def test_dummy_home_links_to_addon_screens
    home = File.read(File.expand_path("dummy/app/views/home/index.html.erb", __dir__))

    assert_includes home, 'title: "Recording Studio AI"'
    assert_includes home, "Playground"
    assert_includes home, "Config"
    assert_includes home, "Methods"
    assert_includes home, "/recording_studio_ai/admin"
    assert_includes home, "/admin/screens/ai_calls"
    refute_includes home, "Foundation ready"
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

  def test_engine_admin_uses_flatpack_tables_modals_and_charts
    views_root = File.expand_path("../app/views/recording_studio_ai/admin", __dir__)
    Dir[File.join(views_root, "**/*.erb")].each do |path|
      contents = File.read(path)
      refute_match(/<table[\s>]/, contents, "#{path} still has a raw table")
      refute_match(/<pre[\s>]/, contents, "#{path} still has a raw pre")
    end

    widgets = File.read(File.expand_path("../lib/recording_studio_ai/admin/recording_studio_ai_widgets.rb", __dir__))
    assert_includes widgets, "FlatPack::Modal::Component"
    assert_includes widgets, "FlatPack::Chart::Component"
    assert_includes widgets, "FlatPack::Link::Component"
    refute_includes widgets, "prompt_namespace"
    refute_includes widgets, "click->flat-pack--modal#clickBackdrop"
  end
end
