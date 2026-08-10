# frozen_string_literal: true

require "rails/generators"

module RecordingStudioAI
  module Generators
    class InstallGenerator < Rails::Generators::Base
      source_root File.expand_path("templates", __dir__)
      namespace "recording_studio_ai:install"

      desc "Install Recording Studio AI into the host application"

      class_option(
        :mount_path,
        type: :string,
        default: "/recording_studio_ai",
        desc: "Route prefix used when mounting the isolated engine"
      )

      def copy_initializer
        template "recording_studio_ai_initializer.rb", "config/initializers/recording_studio_ai.rb"
      end

      def mount_engine
        route %(mount RecordingStudioAI::Engine, at: "#{options[:mount_path]}")
      end

      def show_readme
        readme "INSTALL.md" if behavior == :invoke
      end
    end
  end
end
