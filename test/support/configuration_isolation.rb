# frozen_string_literal: true

module RecordingStudioAI
  module Test
    module ConfigurationIsolation
      def isolate_configuration!(configuration = nil)
        @original_configuration = RecordingStudioAI.instance_variable_get(:@configuration)
        configuration ||= RecordingStudioAI::Configuration.new
        RecordingStudioAI.instance_variable_set(:@configuration, configuration)
        configuration
      end

      def isolate_allow_all_configuration!(configuration = nil)
        configuration = isolate_configuration!(configuration)
        allow_all_authorization!(configuration)
        configuration
      end

      def restore_configuration!
        return unless instance_variable_defined?(:@original_configuration)

        RecordingStudioAI.instance_variable_set(:@configuration, @original_configuration)
        remove_instance_variable(:@original_configuration)
      end

      def allow_all_authorization!(configuration = RecordingStudioAI.configuration)
        configuration.attribution_validator = ->(**) {}
        configuration.authorization_handler = ->(**) { true }
        configuration
      end

      def stub_host_callbacks!
        configuration = RecordingStudioAI.configuration
        @original_authorization_handler = configuration.authorization_handler
        @original_attribution_validator = configuration.attribution_validator
        allow_all_authorization!(configuration)
      end

      def restore_host_callbacks!
        return unless instance_variable_defined?(:@original_authorization_handler)

        configuration = RecordingStudioAI.configuration
        configuration.authorization_handler = @original_authorization_handler
        configuration.attribution_validator = @original_attribution_validator
        remove_instance_variable(:@original_authorization_handler)
        remove_instance_variable(:@original_attribution_validator)
      end

      def isolate_tools_registry!
        @original_tools = RecordingStudioAI.instance_variable_get(:@tools)
        RecordingStudioAI.instance_variable_set(:@tools, RecordingStudioAI::Tools::Registry.new)
      end

      def restore_tools_registry!
        return unless instance_variable_defined?(:@original_tools)

        RecordingStudioAI.instance_variable_set(:@tools, @original_tools)
        remove_instance_variable(:@original_tools)
      end
    end

    class IsolatedCase < Minitest::Test
      include ConfigurationIsolation

      def teardown
        restore_tools_registry!
        restore_host_callbacks!
        restore_configuration!
        super
      end
    end
  end
end
