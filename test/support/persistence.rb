# frozen_string_literal: true

module RecordingStudioAI
  module Test
    module Persistence
      GEM_ROOT = File.expand_path("../..", __dir__)
      MODEL_REQUIRES = %w[
        app/models/recording_studio_ai/application_record
        app/models/concerns/recording_studio_ai/terminal_immutability
        app/models/recording_studio_ai/run
        app/models/recording_studio_ai/attempt
        app/models/recording_studio_ai/custom_tool_invocation
        app/models/recording_studio_ai/batch
        app/models/recording_studio_ai/batch_item
        app/models/recording_studio_ai/response
      ].freeze
      JOB_REQUIRES = %w[
        app/jobs/recording_studio_ai/batch_synchronization_job
        app/jobs/recording_studio_ai/response_cleanup_job
      ].freeze

      class << self
        def load!
          return if @loaded

          require "active_record"
          require "active_job"
          require "sqlite3"
          Dir[File.join(GEM_ROOT, "db/migrate/*.rb")].each { |file| require file }
          (MODEL_REQUIRES + JOB_REQUIRES).each { |path| require File.join(GEM_ROOT, path) }
          @loaded = true
        end

        def migration_classes_for(schema)
          load!
          classes = [
            CreateRecordingStudioAIPersistenceTables,
            AddPromptAttributionToRecordingStudioAIRuns,
            RemoveCorrelationIdsFromRecordingStudioAI
          ]
          return classes unless schema == :hardened

          classes + [
            HardenRecordingStudioAIPersistence,
            EnforceRecordingStudioAIHistoryIntegrity
          ]
        end
      end

      def connect_sqlite_memory!
        ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
      end

      def bootstrap_host_tables!(events: false)
        connection = ActiveRecord::Base.connection
        connection.create_table(:recording_studio_recordings, &:timestamps)
        return unless events

        connection.create_table(:recording_studio_events) do |table|
          table.references :recording
          table.string :action
        end
      end

      def migrate_persistence!(schema: :core)
        ActiveRecord::Migration.suppress_messages do
          Persistence.migration_classes_for(schema).each { |migration| migration.migrate(:up) }
        end
      end

      def create_recording_id
        ActiveRecord::Base.connection.insert(
          "INSERT INTO recording_studio_recordings (created_at, updated_at) " \
          "VALUES (CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)"
        )
      end

      def reset_persistence_models!
        [
          RecordingStudioAI::Run,
          RecordingStudioAI::Attempt,
          RecordingStudioAI::CustomToolInvocation,
          RecordingStudioAI::Batch,
          RecordingStudioAI::BatchItem,
          RecordingStudioAI::Response
        ].each(&:reset_column_information)
      end

      def disconnect_sqlite!
        return unless defined?(ActiveRecord::Base)

        ActiveRecord::Base.remove_connection
      end
    end
  end
end
