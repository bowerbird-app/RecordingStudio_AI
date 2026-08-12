# frozen_string_literal: true

require "timeout"
require "socket"

module RecordingStudioAI
  module Providers
    module ProviderError
      module_function

      def expected?(error)
        error_name = error.class.name
        error.respond_to?(:status) || error.respond_to?(:status_code) ||
          error.is_a?(Timeout::Error) || error.is_a?(SocketError) ||
          error.is_a?(Errno::ECONNREFUSED) || error.is_a?(Errno::ECONNRESET) ||
          error_name.end_with?("TimeoutError") || error_name.end_with?("ConnectionError")
      end

      def normalize(error, provider:)
        status = status_for(error)
        category, retryable = classification(error, status)

        RecordingStudioAI::Contracts::NormalizedError.new(
          category: category,
          code: code_for(category, status),
          message: message_for(category),
          retryable: retryable,
          provider: provider.to_s,
          provider_code: provider_code(error, status)
        )
      end

      def status_for(error)
        value = if error.respond_to?(:status)
                  error.status
                elsif error.respond_to?(:status_code)
                  error.status_code
                end
        value.to_i if value
      end

      def classification(error, status)
        error_name = error.class.name
        return ["timeout", true] if error.is_a?(Timeout::Error) || status == 408 || error_name.end_with?("TimeoutError")
        if error.is_a?(SocketError) || error.is_a?(SystemCallError) || error_name.end_with?("ConnectionError")
          return ["connection", true]
        end

        case status
        when 400, 404, 422 then ["invalid_request", false]
        when 401 then ["authentication", false]
        when 403 then ["authorization", false]
        when 429 then ["rate_limit", true]
        when 500..599 then ["provider_unavailable", true]
        else ["provider_error", false]
        end
      end

      def code_for(category, status)
        status ? "http_#{status}" : category
      end

      def provider_code(error, status)
        value = error.code if error.respond_to?(:code)
        (value || status)&.to_s
      end

      def message_for(category)
        {
          "authentication" => "Provider authentication failed.",
          "authorization" => "Provider authorization failed.",
          "invalid_request" => "Provider rejected the request.",
          "rate_limit" => "Provider rate limit exceeded.",
          "timeout" => "Provider request timed out.",
          "connection" => "Provider connection failed.",
          "provider_unavailable" => "Provider is unavailable.",
          "provider_error" => "Provider request failed."
        }.fetch(category)
      end
    end
  end
end
