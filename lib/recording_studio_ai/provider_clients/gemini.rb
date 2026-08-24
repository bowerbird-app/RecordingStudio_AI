# frozen_string_literal: true

require "json"
require "net/http"

module RecordingStudioAI
  module ProviderClients
    class Gemini
      API_BASE = "https://generativelanguage.googleapis.com/v1beta"
      API_ROOT = "#{API_BASE}/models"
      # Provider-returned batch resource names only. Blocks path injection that
      # would call other Gemini endpoints with the host API key.
      BATCH_NAME_PATTERN = %r{\Abatches/[A-Za-z0-9._-]+\z}
      StreamChunk = Data.define(:payload, :text_mode)

      class HttpError < StandardError
        attr_reader :status, :code, :provider_message

        def initialize(status:, code: nil, provider_message: nil)
          @status = status
          @code = code
          @provider_message = provider_message
          super("Gemini request failed")
        end
      end

      def initialize(api_key:, timeout:)
        @api_key = api_key
        @timeout = timeout
      end

      def models
        self
      end

      def generate_content(model:, contents:, config: nil)
        uri = URI("#{API_ROOT}/#{URI.encode_uri_component(model)}:generateContent")
        request = Net::HTTP::Post.new(uri)
        apply_api_key!(request)
        request["Content-Type"] = "application/json"
        request.body = JSON.generate(request_body(contents, config))

        response = Net::HTTP.start(
          uri.hostname,
          uri.port,
          use_ssl: true,
          open_timeout: @timeout,
          read_timeout: @timeout
        ) { |http| http.request(request) }
        raise_http_error(response) unless response.is_a?(Net::HTTPSuccess)

        JSON.parse(response.body)
      end

      def stream_generate_content(model:, contents:, config: nil)
        return enum_for(__method__, model: model, contents: contents, config: config) unless block_given?

        uri = URI("#{API_ROOT}/#{URI.encode_uri_component(model)}:streamGenerateContent")
        uri.query = URI.encode_www_form(alt: "sse")
        request = Net::HTTP::Post.new(uri)
        apply_api_key!(request)
        request["Content-Type"] = "application/json"
        request["Accept"] = "text/event-stream"
        request.body = JSON.generate(request_body(contents, config))

        Net::HTTP.start(
          uri.hostname,
          uri.port,
          use_ssl: true,
          open_timeout: @timeout,
          read_timeout: @timeout
        ) do |http|
          http.request(request) do |response|
            raise_http_error(response) unless response.is_a?(Net::HTTPSuccess)

            parse_sse(response) { |payload| yield StreamChunk.new(payload: payload, text_mode: :delta) }
          end
        end
      end

      def batch_generate_content(model:, requests:)
        uri = URI("#{API_ROOT}/#{URI.encode_uri_component(model)}:batchGenerateContent")
        body = {
          batch: {
            display_name: "recording-studio-ai",
            input_config: {
              requests: {
                requests: requests.map do |entry|
                  { request: request_body(entry.fetch(:contents), entry[:config]), metadata: { key: entry.fetch(:key) } }
                end
              }
            }
          }
        }
        json_request(uri, Net::HTTP::Post, body)
      end

      def get_batch(name)
        uri = URI("#{API_BASE}/#{batch_resource_name!(name)}")
        json_request(uri, Net::HTTP::Get)
      end

      def cancel_batch(name)
        uri = URI("#{API_BASE}/#{batch_resource_name!(name)}:cancel")
        json_request(uri, Net::HTTP::Post, {})
      end

      private

      def batch_resource_name!(name)
        value = name.to_s
        return value if value.match?(BATCH_NAME_PATTERN)

        raise ArgumentError, "Gemini batch name must match batches/<id>"
      end

      def apply_api_key!(request)
        request["x-goog-api-key"] = @api_key
      end

      def json_request(uri, request_class, body = nil)
        request = request_class.new(uri)
        apply_api_key!(request)
        request["Content-Type"] = "application/json"
        request.body = JSON.generate(body) if body
        response = Net::HTTP.start(
          uri.hostname, uri.port, use_ssl: true, open_timeout: @timeout, read_timeout: @timeout
        ) { |http| http.request(request) }
        raise_http_error(response) unless response.is_a?(Net::HTTPSuccess)

        response.body.to_s.empty? ? {} : JSON.parse(response.body)
      end

      def parse_sse(response)
        buffer = +""
        response.read_body do |bytes|
          buffer << bytes
          while (boundary = buffer.match(/\r?\n\r?\n/))
            event = buffer.slice!(0, boundary.end(0))
            payload = sse_payload(event)
            yield JSON.parse(payload) if payload && payload != "[DONE]"
          end
        end
        payload = sse_payload(buffer)
        yield JSON.parse(payload) if payload && payload != "[DONE]"
      rescue JSON::ParserError
        raise HttpError.new(status: 502, code: "invalid_stream_payload")
      end

      def sse_payload(event)
        data = event.lines.filter_map do |line|
          line.delete_prefix("data:").strip if line.start_with?("data:")
        end
        data.join("\n") unless data.empty?
      end

      def request_body(contents, config)
        body = { contents: normalize_contents(contents) }
        instruction = config&.dig(:system_instruction)
        body[:systemInstruction] = { parts: [{ text: instruction }] } if instruction
        generation_config = {}
        generation_config[:responseMimeType] = config[:response_mime_type] if config&.dig(:response_mime_type)
        generation_config[:responseJsonSchema] = config[:response_json_schema] if config&.dig(:response_json_schema)
        body[:generationConfig] = generation_config unless generation_config.empty?
        apply_tools!(body, config&.dig(:tools))
        body
      end

      def apply_tools!(body, tools)
        return if tools.nil? || Array(tools).empty?

        body[:tools] = normalize_tools(tools)
        body[:toolConfig] = { includeServerSideToolInvocations: true } if mixed_builtin_and_custom_tools?(tools)
      end

      def mixed_builtin_and_custom_tools?(tools)
        list = Array(tools)
        builtin = list.any? { |tool| tool.key?(:google_search) || tool.key?(:googleSearch) }
        custom = list.any? { |tool| tool.key?(:function_declarations) || tool.key?(:functionDeclarations) }
        builtin && custom
      end

      def normalize_tools(tools)
        tools.map do |tool|
          if tool.key?(:google_search)
            { googleSearch: tool[:google_search] }
          elsif tool.key?(:function_declarations)
            {
              functionDeclarations: tool[:function_declarations].map do |declaration|
                {
                  name: declaration.fetch(:name),
                  description: declaration.fetch(:description),
                  parameters: declaration.fetch(:parameters)
                }
              end
            }
          else
            tool
          end
        end
      end

      def normalize_contents(contents)
        contents.map do |content|
          {
            role: content.fetch(:role),
            parts: content.fetch(:parts).map { |part| normalize_part(part) }
          }
        end
      end

      def normalize_part(part)
        if part.key?(:inline_data)
          data = part.fetch(:inline_data)
          { inlineData: { mimeType: data.fetch(:mime_type), data: data.fetch(:data) } }
        elsif part.key?(:function_call)
          call = part.fetch(:function_call)
          { functionCall: { name: call.fetch(:name), args: call.fetch(:args) } }
        elsif part.key?(:function_response)
          response = part.fetch(:function_response)
          { functionResponse: { name: response.fetch(:name), response: response.fetch(:response) } }
        else
          part
        end
      end

      def raise_http_error(response)
        parsed = JSON.parse(response.body)
        raise HttpError.new(
          status: response.code.to_i,
          code: parsed.dig("error", "status"),
          provider_message: parsed.dig("error", "message")
        )
      rescue JSON::ParserError
        raise HttpError.new(status: response.code.to_i)
      end
    end
  end
end
