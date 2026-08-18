# frozen_string_literal: true

module RecordingStudioAI
  module Test
    class PersistenceCase < IsolatedCase
      include Persistence

      def setup
        Persistence.load!
        before_connect
        connect_sqlite_memory!
        bootstrap_host_tables!(events: host_events?)
        migrate_persistence!(schema: persistence_schema)
        reset_persistence_models! if reset_persistence_columns?
      end

      def teardown
        remove_recording_lookup_double
        disconnect_sqlite!
        super
      end

      def before_connect; end

      def persistence_schema
        :core
      end

      def host_events?
        false
      end

      def reset_persistence_columns?
        false
      end

      def install_recording_lookup_double
        return if RecordingStudio.const_defined?(:Recording, false)

        test_case = self
        RecordingStudio.const_set(:Recording, Class.new do
          define_singleton_method(:find) { |id| test_case.build_recording_lookup(id) }
        end)
        @remove_recording_lookup_double = true
      end

      def build_recording_lookup(id)
        self.class::Actor.new(id)
      end

      def remove_recording_lookup_double
        return unless instance_variable_defined?(:@remove_recording_lookup_double) && @remove_recording_lookup_double

        RecordingStudio.send(:remove_const, :Recording) if RecordingStudio.const_defined?(:Recording, false)
        @remove_recording_lookup_double = false
      end
    end
  end
end
