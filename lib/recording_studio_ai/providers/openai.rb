# frozen_string_literal: true

require "base64"
require "json"
require "stringio"

module RecordingStudioAI
  module Providers
    class OpenAI < Base
      provider_key :openai

      include ValueReader

      RETRYABLE_STREAM_ERROR_CODES = %w[
        rate_limit_exceeded
        server_error
        timeout
        connection_error
      ].freeze

      def initialize(configuration:)
        @configuration = configuration
      end

      def configured?
        !@configuration.openai_client.nil? || present?(@configuration.openai_api_key)
      end

      def generate(request:, candidate:)
        response = client.responses.create(**request_parameters(request, candidate))
        response_error = normalize_response_error(response)
        citations = normalize_citations(response)
        web_search_used = web_search_used?(response)
        usage = normalize_usage(read_value(response, :usage))
        Result.new(
          text: read_value(response, :output_text),
          citations: citations,
          provider_native_tools: web_search_used ? ["web_search"] : [],
          tool_calls: normalize_tool_calls(response),
          finish_reason: read_value(response, :status)&.to_s,
          usage: usage,
          provider_request_id: read_value(response, :id),
          error: response_error,
          retention_snapshot: provider_retention_snapshot(response, usage: usage, error: response_error)
        )
      rescue JSON::ParserError
        Result.new(error: invalid_tool_arguments_error)
      rescue StandardError => e
        raise unless ProviderError.expected?(e)

        error = ProviderError.normalize(e, provider: :openai)
        Result.new(error: error, retention_snapshot: error_retention_snapshot(error))
      end

      def stream(request:, candidate:)
        final_response = nil
        terminal_error = nil

        client.responses.stream(**request_parameters(request, candidate)).each do |event|
          case read_value(event, :type).to_s
          when "response.output_text.delta"
            delta = read_value(event, :delta).to_s
            yield StreamEvent.new(type: :text_delta, text_delta: delta) unless delta.empty?
          when "response.completed"
            final_response = read_value(event, :response)
          when "response.failed", "response.incomplete"
            final_response = read_value(event, :response)
            terminal_error = stream_terminal_error(event)
          when "error"
            terminal_error = stream_terminal_error(event)
          end
        end

        if terminal_error && final_response.nil?
          return Result.new(error: terminal_error, retention_snapshot: error_retention_snapshot(terminal_error))
        end

        result = normalize_result(final_response, fallback_error: terminal_error)
        result.citations.each { |citation| yield StreamEvent.new(type: :citation, citation: citation) }
        result
      rescue JSON::ParserError
        Result.new(error: invalid_tool_arguments_error)
      rescue StandardError => e
        raise unless ProviderError.expected?(e)

        error = ProviderError.normalize(e, provider: :openai)
        Result.new(error: error, retention_snapshot: error_retention_snapshot(error))
      end

      def submit_batch(request:, candidate:)
        input = StringIO.new(request.fetch(:items).map do |item|
          JSON.generate(custom_id: item.fetch(:reference), method: "POST", url: "/v1/responses",
                        body: request_parameters(item, candidate))
        end.join("\n") + "\n")
        input.define_singleton_method(:original_filename) { "recording_studio_ai_batch.jsonl" }
        input.define_singleton_method(:content_type) { "application/jsonl" }
        uploaded = client.files.create(file: input, purpose: :batch)
        response = client.batches.create(
          input_file_id: read_value(uploaded, :id), endpoint: :"/v1/responses", completion_window: :"24h"
        )
        normalize_batch_result(response)
      rescue StandardError => error
        raise unless ProviderError.expected?(error)

        BatchResult.new(status: "failed", error: ProviderError.normalize(error, provider: :openai))
      end

      def refresh_batch(batch:, candidate:)
        response = client.batches.retrieve(batch.provider_batch_id)
        normalize_batch_result(response, batch: batch)
      rescue JSON::ParserError
        BatchResult.new(
          status: "failed", provider_batch_id: batch.provider_batch_id,
          error: Contracts::NormalizedError.new(
            category: "invalid_response", code: "invalid_batch_output",
            message: "Provider returned an invalid batch response.", retryable: false, provider: "openai"
          )
        )
      rescue StandardError => error
        raise unless ProviderError.expected?(error)

        BatchResult.new(status: batch.status, provider_batch_id: batch.provider_batch_id,
                        error: ProviderError.normalize(error, provider: :openai))
      end

      def cancel_batch(batch:, candidate:)
        normalize_batch_result(client.batches.cancel(batch.provider_batch_id), batch: batch)
      rescue StandardError => error
        raise unless ProviderError.expected?(error)

        BatchResult.new(status: batch.status, provider_batch_id: batch.provider_batch_id,
                        error: ProviderError.normalize(error, provider: :openai))
      end

      private

      def normalize_batch_result(response, batch: nil)
        status = normalize_batch_status(read_value(response, :status))
        items = batch_output_items(response, batch)
        provider_error = batch_error(response)
        BatchResult.new(
          provider_batch_id: read_value(response, :id), status: status, items: items,
          expires_at: timestamp(read_value(response, :expires_at)), error: provider_error,
          metadata: { request_counts: serializable_request_counts(read_value(response, :request_counts)) }.compact
        )
      end

      def batch_output_items(response, batch)
        output = parse_jsonl_file(read_value(response, :output_file_id))
        errors = parse_jsonl_file(read_value(response, :error_file_id))
        (output + errors).filter_map { |entry| normalize_batch_item(entry, batch) }
      end

      def parse_jsonl_file(file_id)
        return [] unless file_id

        content = client.files.content(file_id)
        content = content.read if content.respond_to?(:read)
        content.to_s.lines.filter_map do |line|
          JSON.parse(line, symbolize_names: true) unless line.strip.empty?
        end
      end

      def normalize_batch_item(entry, batch)
        reference = read_value(entry, :custom_id)
        return unless reference

        response = read_value(entry, :response)
        body = read_value(response, :body)
        request_id = read_value(response, :request_id)
        provider_error = read_value(entry, :error) || read_value(body, :error)
        if provider_error || read_value(response, :status_code).to_i >= 400
          normalized_error = normalized_batch_item_error(provider_error, read_value(response, :status_code))
          return BatchItemResult.new(
            reference: reference, provider_item_id: request_id, status: "failed",
            error: normalized_error, retention_snapshot: error_retention_snapshot(normalized_error)
          )
        end

        result = normalize_result(body)
        structured_data = parse_batch_structured_data(result.text, batch, reference)
        BatchItemResult.new(
          reference: reference, provider_item_id: result.provider_request_id || request_id,
          status: result.success? ? "completed" : "failed", text: result.text,
          structured_data: structured_data, citations: result.citations,
          provider_native_tools: result.provider_native_tools, finish_reason: result.finish_reason,
          usage: result.usage, cost: result.cost, error: result.error,
          retention_snapshot: provider_retention_snapshot(body, usage: result.usage, error: result.error)
        )
      end

      def parse_batch_structured_data(text, batch, reference)
        item = if batch&.respond_to?(:batch_items)
                 batch.batch_items.find { |candidate| candidate.reference == reference.to_s }
               end
        return nil unless item&.metadata&.fetch("structured_output", false)

        JSON.parse(text)
      rescue JSON::ParserError
        nil
      end

      def normalize_batch_status(status)
        case status.to_s
        when "validating" then "submitted"
        when "in_progress", "finalizing", "cancelling" then "processing"
        when "completed" then "completed"
        when "failed" then "failed"
        when "cancelled" then "cancelled"
        when "expired" then "expired"
        else "submitted"
        end
      end

      def batch_error(response)
        return unless %w[failed expired].include?(read_value(response, :status).to_s)

        expired = read_value(response, :status).to_s == "expired"
        Contracts::NormalizedError.new(
          category: expired ? "batch_expired" : "provider_error", code: expired ? "batch_expired" : "batch_failed",
          message: expired ? "Provider batch expired." : "Provider batch failed.", retryable: false, provider: "openai"
        )
      end

      def normalized_batch_item_error(error, status_code)
        Contracts::NormalizedError.new(
          category: "provider_error", code: read_value(error, :code) || "batch_item_failed",
          message: "Provider batch item failed.", retryable: false, provider: "openai",
          provider_code: status_code&.to_s
        )
      end

      def serializable_request_counts(counts)
        return unless counts

        %i[total completed failed].to_h { |key| [key, read_value(counts, key)] }.compact
      end

      def timestamp(value)
        Time.at(value) if value
      end

      def normalize_result(response, fallback_error: nil)
        return Result.new(error: fallback_error || missing_stream_completion_error) unless response

        citations = normalize_citations(response)
        web_search_used = web_search_used?(response)
        usage = normalize_usage(read_value(response, :usage))
        error = fallback_error || normalize_response_error(response)
        Result.new(
          text: read_value(response, :output_text) || response_output_text(response),
          citations: citations,
          provider_native_tools: web_search_used ? ["web_search"] : [],
          tool_calls: normalize_tool_calls(response),
          finish_reason: read_value(response, :status)&.to_s,
          usage: usage,
          provider_request_id: read_value(response, :id),
          error: error,
          retention_snapshot: provider_retention_snapshot(response, usage: usage, error: error)
        )
      end

      def provider_retention_snapshot(response, usage:, error:)
        {
          id: read_value(response, :id),
          model: read_value(response, :model),
          status: read_value(response, :status),
          finish_reason: read_value(response, :status),
          usage: usage&.to_h,
          error: error&.to_h
        }.compact
      end

      def error_retention_snapshot(error)
        { status: "failed", error: error.to_h }
      end

      def response_output_text(response)
        Array(read_value(response, :output)).flat_map do |item|
          Array(read_value(item, :content)).filter_map do |content|
            read_value(content, :text) if read_value(content, :type).to_s == "output_text"
          end
        end.join
      end

      def stream_terminal_error(event)
        type = read_value(event, :type).to_s
        provider_error = read_value(event, :error) || read_value(read_value(event, :response), :error)
        provider_code = read_value(provider_error, :code)&.to_s
        incomplete = type == "response.incomplete"
        retryable = !incomplete && retryable_stream_error_code?(provider_code)
        RecordingStudioAI::Contracts::NormalizedError.new(
          category: incomplete ? "invalid_response" : stream_error_category(provider_code),
          code: incomplete ? "incomplete" : (provider_code || "failed"),
          message: incomplete ? "Provider returned an incomplete response." : "Provider request failed.",
          retryable: retryable,
          provider: "openai",
          provider_code: provider_code
        )
      end

      def retryable_stream_error_code?(code)
        RETRYABLE_STREAM_ERROR_CODES.include?(code) || code&.match?(/(?:^|_)5\d\d$/)
      end

      def stream_error_category(code)
        return "rate_limit" if code == "rate_limit_exceeded"
        return "timeout" if code == "timeout"
        return "connection" if code == "connection_error"
        return "provider_unavailable" if retryable_stream_error_code?(code)

        "provider_error"
      end

      def missing_stream_completion_error
        RecordingStudioAI::Contracts::NormalizedError.new(
          category: "invalid_response",
          code: "missing_stream_completion",
          message: "Provider stream ended without a completed response.",
          retryable: false,
          provider: "openai"
        )
      end

      def client
        @configuration.openai_client || build_client
      end

      def build_client
        require "openai"
        ::OpenAI::Client.new(api_key: @configuration.openai_api_key)
      end

      def request_parameters(request, candidate)
        parameters = {
          model: candidate.model,
          input: normalize_input(request),
          instructions: request[:system_instruction],
          store: false
        }
        parameters[:temperature] = request[:temperature] unless request[:temperature].nil?
        parameters[:max_output_tokens] = request[:max_output_tokens] unless request[:max_output_tokens].nil?
        text = {}
        text[:verbosity] = request[:verbosity] if request[:verbosity]
        text.merge!(structured_output_config(request[:schema])) if request[:schema]
        parameters[:text] = text unless text.empty?
        if request[:reasoning_effort]
          parameters[:reasoning] = { effort: request[:reasoning_effort] }
        end
        tools = []
        tools << { type: "web_search" } if request[:provider_native_tools].include?(:web_search)
        tools.concat(custom_tool_definitions(request))
        parameters[:tools] = tools unless tools.empty?
        parameters.compact
      end

      def normalize_input(request)
        history = Array(request[:custom_tool_history])
        return normalize_initial_input(request) if history.empty?

        initial = normalize_initial_input(request)
        items = initial.is_a?(Array) ? initial : [{ role: "user", content: initial }]
        items + history.flat_map { |round| openai_tool_history(round) }
      end

      def normalize_initial_input(request)

        if request[:prompt]
          return request[:prompt] if request[:attachments].empty?

          return [{ role: "user",
                    content: [{ type: "input_text", text: request[:prompt] }] + attachment_parts(request) }]
        end

        messages = request[:messages].map do |message|
          {
            role: (message[:role] || message["role"]).to_s,
            content: message[:content] || message["content"]
          }
        end
        add_attachments_to_messages(messages, request)
      end

      def openai_tool_history(round)
        calls = round.fetch(:calls).map do |call|
          {
            type: "function_call",
            call_id: call.fetch(:provider_tool_call_id),
            name: call.fetch(:key),
            arguments: JSON.generate(call.fetch(:arguments))
          }
        end
        outputs = round.fetch(:results).map do |result|
          {
            type: "function_call_output",
            call_id: result.fetch(:provider_tool_call_id),
            output: JSON.generate(result.fetch(:result))
          }
        end
        calls + outputs
      end

      def structured_output_config(schema)
        {
          format: {
            type: "json_schema",
            name: "recording_studio_ai_response",
            schema: schema,
            strict: true
          }
        }
      end

      def custom_tool_definitions(request)
        Array(request[:custom_tool_definitions]).map do |definition|
          {
            type: "function",
            name: definition.key,
            description: definition.provider_description,
            parameters: definition.json_schema,
            strict: true
          }
        end
      end

      def normalize_tool_calls(response)
        Array(read_value(response, :output)).filter_map do |item|
          next unless read_value(item, :type).to_s == "function_call"

          RecordingStudioAI::Providers::ToolCall.new(
            provider_tool_call_id: read_value(item, :call_id, :id),
            key: read_value(item, :name),
            arguments: JSON.parse(read_value(item, :arguments).to_s)
          )
        end
      end

      def invalid_tool_arguments_error
        RecordingStudioAI::Contracts::NormalizedError.new(
          category: "invalid_response",
          code: "invalid_tool_arguments",
          message: "Provider returned invalid custom-tool arguments.",
          retryable: false,
          provider: "openai"
        )
      end

      def attachment_parts(request)
        request[:attachments].map do |attachment|
          encoded = Base64.strict_encode64(attachment[:data])
          if attachment[:type] == :image
            { type: "input_image", image_url: "data:#{attachment[:content_type]};base64,#{encoded}" }
          else
            {
              type: "input_file",
              filename: attachment[:filename] || "attachment",
              file_data: "data:#{attachment[:content_type]};base64,#{encoded}"
            }
          end
        end
      end

      def add_attachments_to_messages(messages, request)
        return messages if request[:attachments].empty?

        index = messages.rindex { |message| message[:role] == "user" }
        return messages unless index

        messages[index] = messages[index].merge(
          content: [{ type: "input_text", text: messages[index][:content] }] + attachment_parts(request)
        )
        messages
      end

      def normalize_usage(usage)
        return nil unless usage

        input_details = read_value(usage, :input_tokens_details)
        output_details = read_value(usage, :output_tokens_details)
        RecordingStudioAI::Contracts::Usage.new(
          input_tokens: read_value(usage, :input_tokens),
          output_tokens: read_value(usage, :output_tokens),
          total_tokens: read_value(usage, :total_tokens),
          cached_input_tokens: read_value(input_details, :cached_tokens),
          reasoning_tokens: read_value(output_details, :reasoning_tokens)
        )
      end

      def normalize_response_error(response)
        status = read_value(response, :status)&.to_s
        return nil unless %w[failed incomplete cancelled].include?(status)

        provider_error = read_value(response, :error)
        category = status == "cancelled" ? "cancelled" : "provider_error"
        RecordingStudioAI::Contracts::NormalizedError.new(
          category: category,
          code: status,
          message: status == "cancelled" ? "Provider request was cancelled." : "Provider request failed.",
          retryable: false,
          provider: "openai",
          provider_code: read_value(provider_error, :code)&.to_s
        )
      end

      def normalize_citations(response)
        Array(read_value(response, :output)).flat_map do |item|
          next [] unless read_value(item, :type).to_s == "message"

          Array(read_value(item, :content)).flat_map do |content|
            Array(read_value(content, :annotations)).filter_map do |annotation|
              next unless read_value(annotation, :type).to_s == "url_citation"

              url = read_value(annotation, :url)
              next unless url

              RecordingStudioAI::Contracts::Citation.new(
                title: read_value(annotation, :title).to_s,
                url: url,
                positions: {
                  "start" => read_value(annotation, :start_index),
                  "end" => read_value(annotation, :end_index)
                }.compact
              )
            end
          end
        end
      end

      def web_search_used?(response)
        Array(read_value(response, :output)).any? do |item|
          read_value(item, :type).to_s.include?("web_search")
        end
      end

      def present?(value)
        !value.nil? && !value.to_s.empty?
      end
    end
  end
end
