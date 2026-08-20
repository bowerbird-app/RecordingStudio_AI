# frozen_string_literal: true

module RecordingStudioAI
  module Webhooks
    # OpenAI batch webhook payloads look like:
    # { "id" => "evt_...", "type" => "batch.completed", "data" => { "id" => "batch_..." } }
    module OpenaiBatchPayload
      BATCH_EVENT_PREFIX = "batch."

      module_function

      def provider_batch_id(payload)
        hash = normalize_hash(payload)
        return nil if hash.nil?

        data = hash[:data] || hash["data"]
        data = normalize_hash(data)
        return nil if data.nil?

        id = data[:id] || data["id"]
        id = id.to_s.strip
        id.empty? ? nil : id
      end

      def provider_batch_id!(payload)
        id = provider_batch_id(payload)
        if id.nil?
          raise RecordingStudioAI::Errors::ContractValidationError.new(
            "OpenAI batch webhook payload is missing data.id",
            code: "invalid_request"
          )
        end

        id
      end

      def batch_event?(payload)
        hash = normalize_hash(payload)
        return false if hash.nil?

        type = (hash[:type] || hash["type"]).to_s
        type.start_with?(BATCH_EVENT_PREFIX)
      end

      def event_id(payload)
        hash = normalize_hash(payload)
        return nil if hash.nil?

        id = (hash[:id] || hash["id"]).to_s.strip
        id.empty? ? nil : id
      end

      def normalize_hash(value)
        return value if value.is_a?(Hash)
        return value.to_h if value.respond_to?(:to_h)

        nil
      rescue StandardError
        nil
      end
      module_function :normalize_hash
    end
  end
end
