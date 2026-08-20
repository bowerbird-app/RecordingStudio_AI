# frozen_string_literal: true

require "recording_studio"
require "recording_studio_ai/version"
require "recording_studio_ai/configuration"
require "recording_studio_ai/engine"
require "recording_studio_ai/errors"
require "recording_studio_ai/contracts"
require "recording_studio_ai/metadata"
require "recording_studio_ai/authorization"
require "recording_studio_ai/accessible_authorization"
require "recording_studio_ai/tools"
require "recording_studio_ai/prompts"
require "recording_studio_ai/models"
require "recording_studio_ai/attachments"
require "recording_studio_ai/cost_calculator"
require "recording_studio_ai/structured_output"
require "recording_studio_ai/capabilities"
require "recording_studio_ai/candidate"
require "recording_studio_ai/resolver"
require "recording_studio_ai/providers"
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
      discover_providers! if configuration.discovery_enabled
      configuration.validate!
    end

    def register_provider(key, provider)
      unless provider.is_a?(RecordingStudioAI::Providers::Base)
        raise RecordingStudioAI::Errors::ContractValidationError.new(
          "provider must inherit from RecordingStudioAI::Providers::Base",
          code: "configuration"
        )
      end

      configuration.providers[key.to_sym] = provider
    end

    def discover_providers!
      loaded_files = provider_discovery_globs.flat_map { |glob| Dir.glob(glob) }.uniq.sort
      loaded_files.each { |file| require file }

      discovered = []
      discovered_provider_classes.each do |provider_class|
        provider_key = provider_class.provider_key
        next if configuration.providers.key?(provider_key)

        register_provider(provider_key, provider_class.new(configuration: configuration))
        discovered << provider_key
      end

      discovered
    end

    def generate(**, &block)
      request = Contracts::RequestValidation.validate_generation_request!(**)
      configuration.validate!

      if request[:stream]
        return stream_enumerator(**) unless block

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
        Orchestrator.new.stream(request, &block)
      else
        if block
          raise Errors::ContractValidationError.new(
            "generate only accepts a block when stream: true",
            code: "invalid_request"
          )
        end

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
    end

    def generate!(**kwargs, &block)
      if kwargs.fetch(:stream, false) && !block
        raise Errors::ContractValidationError.new(
          "generate!(stream: true) requires a block to receive streaming events",
          code: "invalid_request"
        )
      end

      response = generate(**kwargs, &block)
      raise Errors::ExecutionError, response unless response.success?

      response
    end

    def submit_batch(**)
      request = Contracts::RequestValidation.validate_batch_submit_request!(**)
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

    def refresh_batch(**)
      request = Contracts::RequestValidation.validate_batch_lookup_request!(**)
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

    def refresh_batch_async(**)
      request = Contracts::RequestValidation.validate_batch_lookup_request!(**)
      configuration.validate!
      Authorization.authorize!(
        :view_execution,
        attribution: request[:attribution],
        context: {
          operation: "batch_refresh",
          batch_id: request[:batch_id]
        }
      )
      enqueue_batch_synchronization(request)
    end

    def cancel_batch(**)
      request = Contracts::RequestValidation.validate_batch_lookup_request!(**)
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

    def read_retained_response(**)
      ResponseReader.new.read(**)
    end

    def tools
      @tools ||= RecordingStudioAI::Tools::Registry.new
    end

    def prompts
      @prompts ||= RecordingStudioAI::Prompts::Registry.new
    end

    def models
      return @models if @models

      @models = RecordingStudioAI::Models::Registry.new
      load_builtin_models!
      @models
    end

    def load_builtin_models!
      Dir.glob(File.expand_path("recording_studio_ai/models/*/*.rb", __dir__)).each do |file|
        load file
      end
    end

    def prompt(key, version: nil)
      definition = prompts.fetch(key, version: version)
      unless definition
        raise RecordingStudioAI::Errors::ContractValidationError.new(
          "prompt #{key}#{" version #{version}" if version} is not registered",
          code: "invalid_request"
        )
      end

      RecordingStudioAI::Prompts::Invocation.new(definition)
    end

    def prompt_methods
      @prompt_methods ||= RecordingStudioAI::Prompts::MethodProxy.new(prompts)
    end

    private

    def stream_enumerator(**kwargs)
      Enumerator.new do |events|
        generate(**kwargs, stream: true) { |event| events << event }
      end
    end

    def enqueue_batch_synchronization(request)
      attribution = request.fetch(:attribution)
      configuration.batch_synchronization_job_class.perform_later(
        batch_id: request.fetch(:batch_id),
        root_recording: attribution.root_recording,
        initiator: attribution.initiator,
        initiator_kind: attribution.initiator_kind,
        context_recording: attribution.context_recording,
        executor: attribution.executor,
        impersonator: attribution.impersonator,
        execution_source: :job,
        request_id: attribution.request_id
      )
    end

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

    def provider_discovery_globs
      globs = [File.expand_path("recording_studio_ai/providers/*.rb", __dir__)]

      if defined?(Rails) && Rails.respond_to?(:root) && Rails.root
        globs << Rails.root.join("lib/recording_studio_ai/providers/*.rb").to_s
      end

      globs.uniq
    end

    def discovered_provider_classes
      RecordingStudioAI::Providers.constants.filter_map do |constant_name|
        constant = RecordingStudioAI::Providers.const_get(constant_name)
        next unless constant.is_a?(Class)
        next if constant == RecordingStudioAI::Providers::Base
        next unless constant < RecordingStudioAI::Providers::Base

        constant
      end.sort_by(&:name)
    end
  end
end
