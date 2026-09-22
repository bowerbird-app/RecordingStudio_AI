# frozen_string_literal: true

require "json"
require "net/http"

module RecordingStudioAI
  module ProviderClients
    class TypeSafe
      API_ROOT = "https://api.typesafe.ai"
      SYSTEM_ONE_PATH = "/v1/systemone"

      class HttpError < StandardError
        attr_reader :status, :code, :provider_message

        def initialize(status:, code: nil, provider_message: nil)
          @status = status
          @code = code
          @provider_message = provider_message
          super("TypeSafe request failed")
        end
      end

      def initialize(api_key:, timeout:)
        @api_key = api_key
        @timeout = timeout
      end

      def decide(model:, state:, questions:)
        uri = URI("#{API_ROOT}#{SYSTEM_ONE_PATH}")
        response = post(uri, JSON.generate(model: model, state: state, questions: questions))
        raise_http_error(response) unless response.is_a?(Net::HTTPSuccess)

        JSON.parse(response.body)
      end

      private

      def post(uri, body)
        request = Net::HTTP::Post.new(uri)
        request["Authorization"] = "Bearer #{@api_key}"
        request["Content-Type"] = "application/json"
        request.body = body

        Net::HTTP.start(
          uri.hostname, uri.port, use_ssl: true, open_timeout: @timeout, read_timeout: @timeout
        ) { |http| http.request(request) }
      end

      def raise_http_error(response)
        error = error_body(response.body)
        raise HttpError.new(
          status: response.code.to_i,
          code: error["code"],
          provider_message: error["message"]
        )
      end

      def error_body(body)
        parsed = JSON.parse(body.to_s)
        return {} unless parsed.is_a?(Hash)

        nested = parsed["error"]
        nested.is_a?(Hash) ? nested : parsed
      rescue JSON::ParserError
        {}
      end
    end
  end
end
