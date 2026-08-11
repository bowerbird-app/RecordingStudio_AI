# frozen_string_literal: true

require "recording_studio"
require "recording_studio_ai/version"
require "recording_studio_ai/configuration"
require "recording_studio_ai/engine"
require "recording_studio_ai/errors"
require "recording_studio_ai/contracts"
require "recording_studio_ai/metadata"
require "recording_studio_ai/authorization"
require "recording_studio_ai/tools"
require "recording_studio_ai/attachments"
require "recording_studio_ai/cost_calculator"
require "recording_studio_ai/structured_output"
require "recording_studio_ai/capabilities"
require "recording_studio_ai/candidate"
require "recording_studio_ai/resolver"
require "recording_studio_ai/adapters"
require "recording_studio_ai/retention"
require "recording_studio_ai/instrumentation"
require "recording_studio_ai/response_reader"
require "recording_studio_ai/response_cleanup"
require "recording_studio_ai/history_cleanup"
require "recording_studio_ai/warning_metrics"
require "recording_studio_ai/admin/access"
require "recording_studio_ai/orchestrator"
require "recording_studio_ai/batch_orchestrator"

module RecordingStudioAI
  class << self
    def configuration
      @configuration ||= Configuration.new
    end

    def configure
      return unless block_given?

      yield(configuration)
      configuration.validate!
    end

    def generate(**kwargs)
      request = Contracts::RequestValidation.validate_generation_request!(**kwargs)
      configuration.validate!
      Authorization.authorize!(
        :execute,
        attribution: request[:attribution],
        context: {
          operation: "generation",
          profile: request[:profile],
          purpose: request[:purpose]
        }
      )
      authorize_provider_native_tools!(request)
      Orchestrator.new.generate(request)
    end

    def generate!(**kwargs)
      response = generate(**kwargs)
      raise Errors::ExecutionError, response unless response.success?

      response
    end

    def stream(**kwargs)
      unless block_given?
        return Enumerator.new do |events|
          stream(**kwargs) { |event| events << event }
        end
      end

      request = Contracts::RequestValidation.validate_generation_request!(**kwargs)
      configuration.validate!
      Authorization.authorize!(
        :execute,
        attribution: request[:attribution],
        context: {
          operation: "stream",
          profile: request[:profile],
          purpose: request[:purpose]
        }
      )
      authorize_provider_native_tools!(request, operation: "stream")
      Orchestrator.new.stream(request) { |event| yield event }
    end

    def stream!(**kwargs, &block)
      unless block
        raise Errors::ContractValidationError.new(
          "stream! requires a block to receive streaming events",
          code: "invalid_request"
        )
      end

      response = stream(**kwargs, &block)
      raise Errors::ExecutionError, response unless response.success?

      response
    end

    def submit_batch(**kwargs)
      request = Contracts::RequestValidation.validate_batch_submit_request!(**kwargs)
      configuration.validate!
      Authorization.authorize!(
        :submit_batch,
        attribution: request[:attribution],
        context: {
          operation: "batch_submit",
          profile: request[:profile],
          item_count: request[:items].length
        }
      )
      request[:items].each do |item|
        authorize_provider_native_tools!(
          item.merge(attribution: request[:attribution], profile: request[:profile]),
          operation: "batch_submit"
        )
      end
      BatchOrchestrator.new.submit(request)
    end

    def refresh_batch(**kwargs)
      request = Contracts::RequestValidation.validate_batch_lookup_request!(**kwargs)
      configuration.validate!
      Authorization.authorize!(
        :view_execution,
        attribution: request[:attribution],
        context: {
          operation: "batch_refresh",
          batch_id: request[:batch_id]
        }
      )
      BatchOrchestrator.new.refresh(request)
    end

    def cancel_batch(**kwargs)
      request = Contracts::RequestValidation.validate_batch_lookup_request!(**kwargs)
      configuration.validate!
      Authorization.authorize!(
        :cancel_batch,
        attribution: request[:attribution],
        context: {
          operation: "batch_cancel",
          batch_id: request[:batch_id]
        }
      )
      BatchOrchestrator.new.cancel(request)
    end

    def read_retained_response(**kwargs)
      ResponseReader.new.read(**kwargs)
    end

    def tools
      @tools ||= RecordingStudioAI::Tools::Registry.new
    end

    private

    def authorize_provider_native_tools!(request, operation: "generation")
      return unless request[:provider_native_tools].include?(:web_search)

      Authorization.authorize!(
        :use_provider_native_tool,
        attribution: request[:attribution],
        context: {
          operation: operation,
          tool: "web_search",
          profile: request[:profile],
          purpose: request[:purpose]
        }
      )
    end

    def not_implemented_generation_response(request, operation:)
      Contracts::GenerationResponse.new(
        operation: operation,
        purpose: request[:purpose],
        profile: request[:profile],
        attempts: [],
        error: not_implemented_error,
        metadata: request[:metadata]
      )
    end

    def not_implemented_response(operation:, profile:)
      Contracts::Response.new(
        operation: operation,
        profile: profile,
        attempts: [],
        error: not_implemented_error,
        metadata: {}
      )
    end

    def not_implemented_error
      Contracts::NormalizedError.new(
        category: "configuration",
        code: "not_implemented",
        message: "Provider execution is not implemented yet.",
        retryable: false
      )
    end
  end
end
