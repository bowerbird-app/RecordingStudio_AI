# frozen_string_literal: true

require "uri"

module RecordingStudioAI
  module Metadata
    SENSITIVE_KEY = /(?:authorization|credential|header|cookie|password|passwd|secret|(?:^|[_-])token(?:$|[_-])|api[_-]?key|signed[_-]?url)/i
    PAYLOAD_KEY = /\A(?:prompt|messages?|system_instruction|content|contents|payload|body|file_bytes|attachment(?:_data|_bytes)?|arguments?|results?|tool_(?:arguments?|results?)|raw_(?:request|response)|request_body|response_body)\z/i
    SENSITIVE_QUERY_KEY = /(?:key|token|signature|credential|password|secret|auth|x-amz-|x-goog-)/i

    module_function

    def sanitize!(value, path: "metadata")
      value = Contracts::Containment.ensure_serializable!(value, path: path)
      sanitize_value(value)
    end

    def sanitize_value(value, key: nil)
      return "[REDACTED]" if key && key.to_s.match?(SENSITIVE_KEY)
      return "[REDACTED]" if key && key.to_s.match?(PAYLOAD_KEY)

      case value
      when Hash
        value.each_with_object({}) do |(child_key, child_value), sanitized|
          sanitized[child_key.to_s] = sanitize_value(child_value, key: child_key)
        end
      when Array
        value.map { |item| sanitize_value(item) }
      when String
        sanitize_url(value)
      when Symbol
        value.to_s
      when NilClass, TrueClass, FalseClass, Integer, Float
        value
      end
    end

    def sanitize_url(value)
      uri = URI.parse(value)
      return value unless uri.is_a?(URI::HTTP) && uri.query

      uri.query = URI.encode_www_form(URI.decode_www_form(uri.query).map do |query_key, query_value|
        [query_key, query_key.match?(SENSITIVE_QUERY_KEY) ? "[REDACTED]" : query_value]
      end)
      uri.to_s
    rescue URI::InvalidURIError, ArgumentError
      value
    end
  end
end