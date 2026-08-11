# frozen_string_literal: true

require "json"
require "uri"

module RecordingStudioAI
  module Retention
    SENSITIVE_KEY = /(?:authorization|credential|header|cookie|password|passwd|secret|(?:^|[_-])token(?:$|[_-])|api[_-]?key|signed[_-]?url)/i
    SENSITIVE_QUERY_KEY = /(?:key|token|signature|credential|password|secret|auth|x-amz-|x-goog-)/i
    RAW_SNAPSHOT_KEYS = %w[id model status finish_reason usage error].freeze

    module_function

    def retain_attempt!(attempt, result, configuration: RecordingStudioAI.configuration)
      retain!(attempt: attempt, result: result, configuration: configuration)
    rescue StandardError
      nil
    end

    def retain_batch_item!(batch_item, result, configuration: RecordingStudioAI.configuration)
      return unless result.terminal?

      retain!(batch_item: batch_item, result: result, configuration: configuration)
    rescue StandardError
      nil
    end

    def sanitize(value, configuration: RecordingStudioAI.configuration)
      normalized = sanitize_value(value)
      callback = configuration.response_sanitizer
      return normalized unless callback

      sanitize_value(callback.call(normalized))
    rescue StandardError
      nil
    end

    def sanitize_value(value, key: nil)
      return "[REDACTED]" if key && key.to_s.match?(SENSITIVE_KEY)

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

    def retain!(attempt: nil, batch_item: nil, result:, configuration:)
      return unless configuration.retain_responses

      owner = attempt || batch_item
      owner.with_lock do
        response = owner.response || owner.build_response
        attributes = retained_attributes(attempt: attempt, batch_item: batch_item, result: result,
                                         configuration: configuration)
        response.assign_attributes(attributes)
        response.save!
      end
    end

    def retained_attributes(attempt:, batch_item:, result:, configuration:)
      normalized = sanitize(normalized_result(result), configuration: configuration) || {}
      content = sanitize(result.text, configuration: configuration)
      raw = safe_raw_snapshot(result, configuration)
      bounded = bound_fields(raw: raw, normalized: normalized, content: content,
                             maximum: configuration.maximum_retained_response_size)
      if result.structured_data && bounded[:truncated]
        bounded[:byte_size] -= bounded[:content].to_s.bytesize
        bounded[:content] = nil
      end
      owner = attempt || batch_item

      {
        provider: attempt&.provider || batch_item.batch.provider,
        model: attempt&.model || batch_item.batch.model,
        provider_response_id: result.respond_to?(:provider_item_id) ? result.provider_item_id : result.provider_request_id,
        response_type: response_type(attempt, result),
        raw_response: bounded[:raw],
        normalized_response: bounded[:normalized],
        content_text: bounded[:content],
        content_type: result.structured_data ? "application/json" : "text/plain",
        finish_reason: result.finish_reason,
        complete: retained_result_complete?(result),
        truncated: bounded[:truncated],
        byte_size: bounded[:byte_size],
        expires_at: Time.current + configuration.response_retention_period,
        metadata: metadata_for(owner)
      }
    end

    def normalized_result(result)
      {
        text: result.text,
        structured_data: result.structured_data,
        citations: result.citations.map(&:to_h),
        provider_native_tools: result.provider_native_tools,
        finish_reason: result.finish_reason,
        usage: result.usage&.to_h,
        cost: result.cost&.to_h,
        error: result.error&.to_h
      }.compact
    end

    def retained_result_complete?(result)
      if result.respond_to?(:success?)
        result.success?
      else
        result.status == "completed" && result.error.nil?
      end
    end

    def safe_raw_snapshot(result, configuration)
      return unless result.respond_to?(:retention_snapshot)

      snapshot = result.retention_snapshot
      return unless snapshot.is_a?(Hash) && serializable?(snapshot)

      allowlisted = snapshot.each_with_object({}) do |(key, value), kept|
        kept[key.to_s] = value if RAW_SNAPSHOT_KEYS.include?(key.to_s)
      end
      sanitize(allowlisted, configuration: configuration)
    end

    def serializable?(value)
      JSON.generate(value)
      true
    rescue JSON::GeneratorError, TypeError
      false
    end

    def bound_fields(raw:, normalized:, content:, maximum:)
      maximum = [maximum.to_i, 0].max
      if maximum < 2
        return { raw: nil, normalized: nil, content: nil, truncated: true, byte_size: 0 }
      end

      fields = { raw: json_or_nil(raw), normalized: JSON.generate(normalized), content: content&.to_s }
      original_size = fields.values.compact.sum(&:bytesize)
      return fields.merge(truncated: false, byte_size: original_size) if original_size <= maximum

      fields[:raw] = nil
      fields[:content] = truncate_utf8(fields[:content], [maximum - fields[:normalized].bytesize, 0].max)
      if fields.values.compact.sum(&:bytesize) > maximum
        fields[:normalized] = JSON.generate(truncate_value(normalized, maximum))
        fields[:content] = truncate_utf8(fields[:content], [maximum - fields[:normalized].bytesize, 0].max)
      end
      size = fields.values.compact.sum(&:bytesize)
      fields.merge(truncated: true, byte_size: size)
    end

    def truncate_value(value, maximum)
      return {} if maximum < 2

      candidate = value
      strings = string_paths(candidate).sort_by { |path| -dig_value(candidate, path).bytesize }
      strings.each do |path|
        break if JSON.generate(candidate).bytesize <= maximum

        current = dig_value(candidate, path)
        overhead = JSON.generate(candidate).bytesize - current.bytesize
        set_value(candidate, path, truncate_utf8(current, [maximum - overhead, 0].max))
      end
      JSON.generate(candidate).bytesize <= maximum ? candidate : {}
    end

    def truncate_utf8(value, maximum)
      return value if value.nil? || value.bytesize <= maximum

      value.byteslice(0, maximum).to_s.force_encoding(Encoding::UTF_8).scrub("")
    end

    def string_paths(value, path = [])
      case value
      when Hash
        value.flat_map { |key, child| string_paths(child, path + [key]) }
      when Array
        value.each_index.flat_map { |index| string_paths(value[index], path + [index]) }
      when String
        [path]
      else
        []
      end
    end

    def dig_value(value, path) = path.reduce(value) { |memo, key| memo[key] }

    def set_value(value, path, replacement)
      parent = path[0...-1].reduce(value) { |memo, key| memo[key] }
      parent[path.last] = replacement
    end

    def json_or_nil(value) = value.nil? ? nil : JSON.generate(value)

    def response_type(attempt, result)
      return "batch_item" unless attempt
      return "error" if result.error

      attempt.streaming? ? "stream" : "generation"
    end

    def metadata_for(_owner) = {}
  end
end
