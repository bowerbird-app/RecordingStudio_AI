# frozen_string_literal: true

require "test_helper"
require "rake"

class TailwindGemSourcesTest < ActiveSupport::TestCase
  setup do
    Dummy::Application.load_tasks
  end

  test "tailwind enhance_sources writes Flatpack and engine scan paths" do
    Rake::Task["tailwindcss:enhance_sources"].reenable
    Rake::Task["tailwindcss:enhance_sources"].invoke

    sources = File.read(Rails.root.join("app/assets/tailwind/gem_sources.css"))
    flatpack = Gem.loaded_specs.fetch("flat_pack").full_gem_path
    engine = Gem.loaded_specs.fetch("recording_studio_ai").full_gem_path

    assert_includes sources, "#{flatpack}/app/components/**/*.{rb,erb}"
    assert_includes sources, "#{engine}/app/views/**/*.erb"
    assert_includes sources, "#{engine}/lib/recording_studio_ai/admin/**/*.{rb,erb}"
  end

  test "dummy tailwind entry imports generated gem sources" do
    entry = File.read(Rails.root.join("app/assets/tailwind/application.css"))

    assert_includes entry, '@import "./gem_sources.css"'
  end
end
