# frozen_string_literal: true

require_relative "lib/recording_studio_ai/version"

Gem::Specification.new do |spec|
  spec.name        = "recording_studio_ai"
  spec.version     = RecordingStudioAI::VERSION
  spec.authors     = ["Bowerbird"]
  spec.homepage    = "https://github.com/bowerbird-app/RecordingStudio_AI"
  spec.summary     = "AI capabilities for Recording Studio"
  spec.description = "A Rails engine that adds AI capabilities to Recording Studio."
  spec.license     = "MIT"
  spec.required_ruby_version = ">= 3.3.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "#{spec.homepage}/tree/main"
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    Dir["{app,config,db,lib}/**/*", "CHANGELOG.md", "MIT-LICENSE", "README.md"]
  end

  spec.add_dependency "json_schemer", "~> 2.4"
  spec.add_dependency "csv", ">= 3.2"
  spec.add_dependency "flat_pack", "~> 0.1"
  spec.add_dependency "openai", "~> 0.78"
  spec.add_dependency "rails", ">= 8.1", "< 9.0"
  spec.add_dependency "recording_studio", "~> 3.0"
end
