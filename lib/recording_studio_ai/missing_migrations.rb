# frozen_string_literal: true

module RecordingStudioAI
  # Compares this gem's db/migrate files with the copies in a host app.
  #
  # `recording_studio_ai:install:migrations` writes
  # `<timestamp>_<name>.recording_studio_ai.rb`. The timestamp is new on each
  # copy, so the match is the migration name. A hand copy without that suffix
  # still counts. Rails skips a second copy when the name already exists.
  class MissingMigrations
    INSTALL_COMMAND = "bin/rails recording_studio_ai:install:migrations"

    class Error < StandardError; end

    class Result
      attr_reader :missing, :command

      def initialize(missing:, command:)
        @missing = missing
        @command = command
      end

      def missing?
        !missing.empty?
      end

      def message
        return "Recording Studio AI migrations are installed." unless missing?

        [
          "Recording Studio AI migrations missing from this app:",
          *missing.map { |name| "- #{name}" },
          "Copy them, then migrate:",
          "  #{command}",
          "  bin/rails db:migrate"
        ].join("\n")
      end
    end

    class << self
      def check(host_directory: Rails.root.join("db/migrate"), gem_directory: Engine.root.join("db/migrate"))
        installed = migration_names(host_directory)
        missing = migration_names(gem_directory).reject { |name| installed.include?(name) }
        Result.new(missing: missing, command: INSTALL_COMMAND)
      end

      def report(host_directory: Rails.root.join("db/migrate"), gem_directory: Engine.root.join("db/migrate"))
        result = check(host_directory: host_directory, gem_directory: gem_directory)
        return result unless result.missing?

        raise Error, result.message if RecordingStudioAI.configuration.raise_on_missing_migrations

        warn result.message
        result
      end

      # Development and test only. Production boot must not register this,
      # scan db/migrate, or raise.
      def watch(app)
        return unless Rails.env.local?

        app.config.after_initialize { report }
      end

      private

      def migration_names(directory)
        root = directory.to_s
        return [] unless File.directory?(root)

        Dir.glob(File.join(root, "**", "[0-9]*_*.rb")).filter_map do |file|
          match = File.basename(file).match(ActiveRecord::Migration::MigrationFilenameRegexp)
          next unless match

          name = match[2]
          name unless name.empty?
        end.uniq
      end
    end
  end
end
