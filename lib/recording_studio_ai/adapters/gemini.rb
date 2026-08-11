# frozen_string_literal: true

require "base64"

module RecordingStudioAI
  module Adapters
    class Gemini < Base
      include ValueReader

      def initialize(configuration:)
        @configuration = configuration
      end

      def configured?
        !@configuration.gemini_client.nil? || present?(@configuration.gemini_api_key)
      end

      def generate(request:, candidate:)
        response = client.models.generate_content(
          model: candidate.model,
          contents: normalize_contents(request),
          config: generation_config(request)
        )
        candidate_response = Array(read_value(response, :candidates)).first
        response_error = normalize_response_error(candidate_response)
        citations = normalize_citations(candidate_response)
        web_search_used = !grounding_metadata(candidate_response).nil?
        usage = normalize_usage(read_value(response, :usage_metadata, :usageMetadata))
        Result.new(
          text: response_text(response, candidate_response),
          citations: citations,
          provider_native_tools: web_search_used ? ["web_search"] : [],
          tool_calls: normalize_tool_calls(response, candidate_response),
          finish_reason: normalize_finish_reason(read_value(candidate_response, :finish_reason, :finishReason)),
          usage: usage,
          provider_request_id: read_value(response, :response_id, :responseId),
          error: response_error,
          retention_snapshot: provider_retention_snapshot(
            response, candidate_response: candidate_response, usage: usage, error: response_error
          )
        )
      rescue StandardError => e
        raise unless ProviderError.expected?(e)

        error = ProviderError.normalize(e, provider: :gemini)
        Result.new(error: error, retention_snapshot: error_retention_snapshot(error))
      end

      def stream(request:, candidate:)
        text = +""
        citations = []
        citation_keys = {}
        tool_calls = []
        tool_call_keys = {}
        final_candidate = nil
        finish_reason = nil
        usage = nil
        provider_request_id = nil
        response_error = nil
        web_search_used = false

        client.models.stream_generate_content(
          model: candidate.model,
          contents: normalize_contents(request),
          config: generation_config(request)
        ).each do |chunk|
          text_mode = chunk.respond_to?(:text_mode) ? chunk.text_mode : :delta
          chunk = chunk.payload if chunk.respond_to?(:payload)
          candidate_response = Array(read_value(chunk, :candidates)).first
          chunk_finish_reason = read_value(candidate_response, :finish_reason, :finishReason)
          finish_reason = normalize_finish_reason(chunk_finish_reason) if chunk_finish_reason
          chunk_usage = normalize_usage(read_value(chunk, :usage_metadata, :usageMetadata))
          usage = chunk_usage if chunk_usage
          chunk_request_id = read_value(chunk, :response_id, :responseId)
          provider_request_id = chunk_request_id if chunk_request_id
          chunk_error = normalize_response_error(candidate_response) if candidate_response
          response_error = chunk_error if chunk_error
          web_search_used ||= !grounding_metadata(candidate_response).nil?
          chunk_text = response_text(chunk, candidate_response).to_s
          delta = if text_mode == :cumulative && chunk_text.start_with?(text)
                    chunk_text.delete_prefix(text)
                  else
                    chunk_text
                  end
          unless delta.empty?
            text << delta
            yield StreamEvent.new(type: :text_delta, text_delta: delta)
          end
          normalize_citations(candidate_response).each do |citation|
            key = [citation.url, citation.title, citation.positions]
            next if citation_keys[key]

            citation_keys[key] = true
            citations << citation
            yield StreamEvent.new(type: :citation, citation: citation)
          end
          normalize_tool_calls(chunk, candidate_response).each do |tool_call|
            key = [tool_call.provider_tool_call_id, tool_call.key]
            next if tool_call_keys[key]

            tool_call_keys[key] = true
            tool_calls << tool_call
          end
          final_candidate = candidate_response if candidate_response
        end

        response_error ||= normalize_response_error(final_candidate)
        Result.new(
          text: text,
          citations: citations,
          provider_native_tools: web_search_used ? ["web_search"] : [],
          tool_calls: tool_calls,
          finish_reason: finish_reason,
          usage: usage,
          provider_request_id: provider_request_id,
          error: response_error,
          retention_snapshot: {
            id: provider_request_id, status: response_error ? "failed" : "completed",
            finish_reason: finish_reason, usage: usage&.to_h, error: response_error&.to_h
          }.compact
        )
      rescue StandardError => e
        raise unless ProviderError.expected?(e)

        error = ProviderError.normalize(e, provider: :gemini)
        Result.new(error: error, retention_snapshot: error_retention_snapshot(error))
      end

      def submit_batch(request:, candidate:)
        response = client.batch_generate_content(
          model: candidate.model,
          requests: request.fetch(:items).map do |item|
            { key: item.fetch(:reference), contents: normalize_contents(item), config: generation_config(item) }
          end
        )
        normalize_batch_result(response)
      rescue StandardError => error
        raise unless ProviderError.expected?(error)

        BatchResult.new(status: "failed", error: ProviderError.normalize(error, provider: :gemini))
      end

      def refresh_batch(batch:, candidate:)
        normalize_batch_result(client.get_batch(batch.provider_batch_id), batch: batch)
      rescue StandardError => error
        raise unless ProviderError.expected?(error)

        BatchResult.new(status: batch.status, provider_batch_id: batch.provider_batch_id,
                        error: ProviderError.normalize(error, provider: :gemini))
      end

      def cancel_batch(batch:, candidate:)
        client.cancel_batch(batch.provider_batch_id)
        normalize_batch_result(client.get_batch(batch.provider_batch_id), batch: batch)
      rescue StandardError => error
        raise unless ProviderError.expected?(error)

        BatchResult.new(status: batch.status, provider_batch_id: batch.provider_batch_id,
                        error: ProviderError.normalize(error, provider: :gemini))
      end

      private

      def normalize_batch_result(job, batch: nil)
        payload = read_value(job, :response) || job
        state = read_value(job, :state) || read_value(read_value(job, :metadata), :state) || read_value(payload, :state)
        status = normalize_batch_status(state)
        BatchResult.new(
          provider_batch_id: read_value(job, :name) || read_value(payload, :name) || batch&.provider_batch_id,
          status: status, items: normalize_batch_items(payload, batch), error: normalize_batch_error(status),
          metadata: { provider_state: state&.to_s }.compact
        )
      end

      def normalize_batch_items(payload, batch)
        destination = read_value(payload, :dest, :destination)
        responses = read_value(destination, :inlined_responses, :inlinedResponses) ||
                    read_value(payload, :inlined_responses, :inlinedResponses)
        Array(responses).filter_map do |entry|
          metadata = read_value(entry, :metadata) || {}
          reference = read_value(metadata, :key) || read_value(entry, :key)
          next unless reference

          error = read_value(entry, :error)
          if error
            normalized_error = gemini_batch_item_error(error)
            BatchItemResult.new(
              reference: reference, status: "failed", error: normalized_error,
              retention_snapshot: error_retention_snapshot(normalized_error)
            )
          else
            normalize_successful_batch_item(reference, read_value(entry, :response), batch)
          end
        end
      end

      def normalize_successful_batch_item(reference, response, batch)
        candidate_response = Array(read_value(response, :candidates)).first
        error = normalize_response_error(candidate_response)
        citations = normalize_citations(candidate_response)
        usage = normalize_usage(read_value(response, :usage_metadata, :usageMetadata))
        BatchItemResult.new(
          reference: reference, provider_item_id: read_value(response, :response_id, :responseId),
          status: error ? "failed" : "completed", text: response_text(response, candidate_response),
          structured_data: gemini_batch_structured_data(response_text(response, candidate_response), batch, reference),
          citations: citations, provider_native_tools: grounding_metadata(candidate_response) ? ["web_search"] : [],
          finish_reason: normalize_finish_reason(read_value(candidate_response, :finish_reason, :finishReason)),
          usage: usage, error: error,
          retention_snapshot: provider_retention_snapshot(
            response, candidate_response: candidate_response, usage: usage, error: error
          )
        )
      end

      def provider_retention_snapshot(response, candidate_response:, usage:, error:)
        {
          id: read_value(response, :response_id, :responseId),
          model: read_value(response, :model_version, :modelVersion),
          status: error ? "failed" : "completed",
          finish_reason: normalize_finish_reason(read_value(candidate_response, :finish_reason, :finishReason)),
          usage: usage&.to_h,
          error: error&.to_h
        }.compact
      end

      def error_retention_snapshot(error)
        { status: "failed", error: error.to_h }
      end

      def gemini_batch_structured_data(text, batch, reference)
        item = if batch&.respond_to?(:batch_items)
                 batch.batch_items.find { |candidate| candidate.reference == reference.to_s }
               end
        return nil unless item&.metadata&.fetch("structured_output", false)

        JSON.parse(text)
      rescue JSON::ParserError
        nil
      end

      def normalize_batch_status(state)
        case state.to_s.upcase
        when "JOB_STATE_PENDING", "PENDING" then "submitted"
        when "JOB_STATE_RUNNING", "RUNNING" then "processing"
        when "JOB_STATE_SUCCEEDED", "SUCCEEDED" then "completed"
        when "JOB_STATE_FAILED", "FAILED" then "failed"
        when "JOB_STATE_CANCELLED", "CANCELLED" then "cancelled"
        when "JOB_STATE_EXPIRED", "EXPIRED" then "expired"
        else "submitted"
        end
      end

      def normalize_batch_error(status)
        return unless %w[failed expired].include?(status)

        expired = status == "expired"
        Contracts::NormalizedError.new(
          category: expired ? "batch_expired" : "provider_error",
          code: expired ? "batch_expired" : "batch_failed",
          message: expired ? "Provider batch expired." : "Provider batch failed.",
          retryable: false, provider: "gemini"
        )
      end

      def gemini_batch_item_error(error)
        Contracts::NormalizedError.new(
          category: "provider_error", code: read_value(error, :status, :code) || "batch_item_failed",
          message: "Provider batch item failed.", retryable: false, provider: "gemini"
        )
      end

      def client
        @configuration.gemini_client || RecordingStudioAI::ProviderClients::Gemini.new(
          api_key: @configuration.gemini_api_key,
          timeout: @configuration.request_timeout
        )
      end

      def normalize_contents(request)
        contents = if request[:prompt]
                     [{ role: "user", parts: [{ text: request[:prompt] }] + attachment_parts(request) }]
                   else
                     normalize_message_contents(request)
                   end
        append_custom_tool_continuation(contents, request)
      end

      def normalize_message_contents(request)
        contents = request[:messages].filter_map do |message|
          role = (message[:role] || message["role"]).to_s
          next if role == "system"

          {
            role: role == "assistant" ? "model" : "user",
            parts: [{ text: message[:content] || message["content"] }]
          }
        end
        add_attachments_to_contents(contents, request)
      end

      def append_custom_tool_continuation(contents, request)
        history = Array(request[:custom_tool_history])
        return contents if history.empty?

        contents + history.flat_map do |round|
          [
            {
              role: "model",
              parts: round.fetch(:calls).map do |call|
                { function_call: { name: call.fetch(:key), args: call.fetch(:arguments) } }
              end
            },
            {
              role: "user",
              parts: round.fetch(:results).map do |result|
                {
                  function_response: {
                    name: result.fetch(:tool_key),
                    response: { result: result.fetch(:result) }
                  }
                }
              end
            }
          ]
        end
      end

      def generation_config(request)
        instruction = [request[:system_instruction], system_messages(request)].compact.reject(&:empty?).join("\n")
        config = {}
        config[:system_instruction] = instruction unless instruction.empty?
        if request[:schema]
          config[:response_mime_type] = "application/json"
          config[:response_json_schema] = request[:schema]
        end
        tools = []
        tools << { google_search: {} } if request[:provider_native_tools].include?(:web_search)
        declarations = custom_tool_definitions(request)
        tools << { function_declarations: declarations } unless declarations.empty?
        config[:tools] = tools unless tools.empty?
        config.empty? ? nil : config
      end

      def custom_tool_definitions(request)
        Array(request[:custom_tool_definitions]).map do |definition|
          {
            name: definition.key,
            description: definition.provider_description,
            parameters: definition.json_schema
          }
        end
      end

      def normalize_tool_calls(response, candidate_response)
        content = read_value(candidate_response, :content)
        Array(read_value(content, :parts)).filter_map.with_index do |part, index|
          function_call = read_value(part, :function_call, :functionCall)
          next unless function_call

          name = read_value(function_call, :name).to_s
          response_id = read_value(response, :response_id, :responseId).to_s
          RecordingStudioAI::Adapters::ToolCall.new(
            provider_tool_call_id: "#{response_id.empty? ? 'gemini-tool-call' : response_id}:#{index}",
            key: name,
            arguments: read_value(function_call, :args) || {}
          )
        end
      end

      def attachment_parts(request)
        request[:attachments].map do |attachment|
          {
            inline_data: {
              mime_type: attachment[:content_type],
              data: Base64.strict_encode64(attachment[:data])
            }
          }
        end
      end

      def add_attachments_to_contents(contents, request)
        return contents if request[:attachments].empty?

        index = contents.rindex { |content| content[:role] == "user" }
        contents[index][:parts].concat(attachment_parts(request)) if index
        contents
      end

      def system_messages(request)
        Array(request[:messages]).filter_map do |message|
          role = (message[:role] || message["role"]).to_s
          message[:content] || message["content"] if role == "system"
        end.join("\n")
      end

      def response_text(response, candidate_response)
        direct = read_value(response, :text)
        return direct unless direct.nil?

        content = read_value(candidate_response, :content)
        Array(read_value(content, :parts)).filter_map { |part| read_value(part, :text) }.join
      end

      def normalize_finish_reason(value)
        value&.to_s&.downcase
      end

      def normalize_usage(usage)
        return nil unless usage

        RecordingStudioAI::Contracts::Usage.new(
          input_tokens: read_value(usage, :prompt_token_count, :promptTokenCount),
          output_tokens: read_value(usage, :candidates_token_count, :candidatesTokenCount),
          total_tokens: read_value(usage, :total_token_count, :totalTokenCount),
          cached_input_tokens: read_value(usage, :cached_content_token_count, :cachedContentTokenCount),
          reasoning_tokens: read_value(usage, :thoughts_token_count, :thoughtsTokenCount)
        )
      end

      def normalize_response_error(candidate_response)
        return invalid_response_error unless candidate_response

        reason = read_value(candidate_response, :finish_reason, :finishReason)&.to_s&.upcase
        return content_policy_error if %w[SAFETY BLOCKLIST PROHIBITED_CONTENT].include?(reason)

        nil
      end

      def normalize_citations(candidate_response)
        grounding = grounding_metadata(candidate_response)
        chunks = Array(read_value(grounding, :grounding_chunks, :groundingChunks))
        supports = Array(read_value(grounding, :grounding_supports, :groundingSupports))

        chunks.each_with_index.filter_map do |chunk, index|
          web = read_value(chunk, :web)
          url = read_value(web, :uri, :url)
          next unless url

          positions = supports.filter_map do |support|
            indices = Array(read_value(support, :grounding_chunk_indices, :groundingChunkIndices))
            next unless indices.map(&:to_i).include?(index)

            segment = read_value(support, :segment)
            {
              "start" => read_value(segment, :start_index, :startIndex),
              "end" => read_value(segment, :end_index, :endIndex)
            }.compact
          end
          RecordingStudioAI::Contracts::Citation.new(
            title: read_value(web, :title).to_s,
            url: url,
            positions: positions.empty? ? nil : positions
          )
        end
      end

      def grounding_metadata(candidate_response)
        read_value(candidate_response, :grounding_metadata, :groundingMetadata)
      end

      def invalid_response_error
        RecordingStudioAI::Contracts::NormalizedError.new(
          category: "invalid_response",
          code: "missing_candidate",
          message: "Provider returned no generation candidate.",
          retryable: false,
          provider: "gemini"
        )
      end

      def content_policy_error
        RecordingStudioAI::Contracts::NormalizedError.new(
          category: "content_policy",
          code: "blocked",
          message: "Provider blocked the response under its content policy.",
          retryable: false,
          provider: "gemini"
        )
      end

      def present?(value)
        !value.nil? && !value.to_s.empty?
      end
    end
  end
end
