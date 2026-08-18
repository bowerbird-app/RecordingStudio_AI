# frozen_string_literal: true

require "recording_studio_ai/providers/value_reader"

module RecordingStudioAI
  module Providers
    class Base
      class << self
        def provider_key(value = nil)
          @provider_key = value&.to_sym if value
          @provider_key ||= name.split("::").last.downcase.to_sym
        end
      end

      include ValueReader

      def initialize(configuration: nil)
        @configuration = configuration
      end

      # Credential accessors follow +<provider_key>_client+ / +<provider_key>_api_key+.
      # Adapters without a configuration object, or whose configuration does not
      # expose those accessors, stay configured so test and host stubs keep working.
      def configured?
        return true unless credential_accessors?

        !configuration_client.nil? || present?(configuration_api_key)
      end

      def generate(request:, candidate:)
        raise NotImplementedError, "#{self.class} must implement #generate"
      end

      def stream(request:, candidate:)
        raise NotImplementedError, "#{self.class} must implement #stream"
      end

      def submit_batch(request:, candidate:)
        raise NotImplementedError, "#{self.class} must implement #submit_batch"
      end

      def refresh_batch(batch:, candidate:)
        raise NotImplementedError, "#{self.class} must implement #refresh_batch"
      end

      def cancel_batch(batch:, candidate:)
        raise NotImplementedError, "#{self.class} must implement #cancel_batch"
      end

      private

      def configuration_client
        configuration_setting(:client)
      end

      def configuration_api_key
        configuration_setting(:api_key)
      end

      def credential_accessors?
        return false unless @configuration

        @configuration.respond_to?(setting_name(:client)) ||
          @configuration.respond_to?(setting_name(:api_key))
      end

      def configuration_setting(suffix)
        return unless @configuration&.respond_to?(setting_name(suffix))

        @configuration.public_send(setting_name(suffix))
      end

      def setting_name(suffix)
        "#{self.class.provider_key}_#{suffix}"
      end

      def error_retention_snapshot(error)
        { status: "failed", error: error.to_h }
      end

      def failed_result(error)
        normalized = normalize_failure(error)
        Result.new(error: normalized, retention_snapshot: error_retention_snapshot(normalized))
      end

      def failed_batch_result(error, status: "failed", provider_batch_id: nil)
        BatchResult.new(status: status, provider_batch_id: provider_batch_id, error: normalize_failure(error))
      end

      def normalize_failure(error)
        return error unless error.is_a?(StandardError)

        ProviderError.normalize(error, provider: self.class.provider_key)
      end

      def present?(value)
        !value.nil? && !value.to_s.empty?
      end
    end
  end
end
