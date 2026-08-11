# frozen_string_literal: true

require "digest"
require "json"
require "securerandom"
require "timeout"

module RecordingStudioAI
  class Orchestrator
    class StreamIdleTimeout < Timeout::Error; end
    class ProviderRequestTimeout < Timeout::Error; end

    class StreamConsumerError < StandardError
      attr_reader :original_error

      def initialize(original_error)
        @original_error = original_error
        super("Stream consumer failed")
      end
    end

    PlannedCandidate = Data.define(:candidate, :profile)
    ExecutedAttempt = Data.define(:record, :result)
    class CancellationState
      attr_reader :deadline

      def initialize(deadline:)
        @deadline = deadline
        @cancelled = false
        @mutex = Mutex.new
      end

      def cancel!
        @mutex.synchronize { @cancelled = true }
      end

      def cancelled?
        @mutex.synchronize { @cancelled } || Time.current >= deadline
      end
    end
    CustomToolContext = Data.define(
      :root_recording,
      :context_recording,
      :initiator,
      :executor,
      :run,
      :requesting_attempt,
      :execution_source,
      :deadline,
      :cancellation_state
    )

    def initialize(configuration: RecordingStudioAI.configuration)
      @configuration = configuration
      @resolver = RecordingStudioAI::Resolver.new(configuration: configuration)
    end

    def generate(request)
      request = request.merge(execution_deadline: Time.current + @configuration.total_execution_timeout)
      execute(request, operation: :generation)
    end

    def stream(request, &event_handler)
      request = request.merge(execution_deadline: Time.current + @configuration.total_execution_timeout)
      @event_handler = event_handler
      @visible_stream_output = false
      completed = false
      response = execute(request, operation: :stream)
      emit_final_stream_events(response)
      completed = true
      response
    rescue StreamConsumerError => error
      cancel_active_stream_records!
      raise error.original_error
    ensure
      cancel_active_stream_records! unless completed
      @event_handler = nil
      @visible_stream_output = nil
      @active_run = nil
      @active_attempt = nil
    end

    private

    def execute(request, operation:)
      plan = execution_plan(request, operation: operation)
      run = create_run!(request, plan.first.candidate, operation: operation)
      @active_run = run if operation == :stream
      executions = execute_plan(run, request, plan, operation: operation)
      return complete_deadline_failure(request, run, operation: operation) if executions.empty?

      final_execution = executions.last
      complete_run!(run, executions, final_execution)
      build_response(request, run, executions, final_execution, operation: operation)
    rescue RecordingStudioAI::Errors::ResolutionError => e
      build_resolution_failure(request, e, operation: operation)
    end

    def execution_plan(request, operation:)
      capability_operation = operation == :stream ? :streaming : :generation
      capabilities = RecordingStudioAI::Capabilities.for_request(request, operation: capability_operation)
      profiles = [request[:profile]] + configured_fallback_profiles(request[:profile])
      profiles.flat_map do |profile|
        @resolver.candidates(
          profile: profile,
          provider: request[:provider],
          required_capabilities: capabilities,
          allow_empty: profile != request[:profile]
        ).map { |candidate| PlannedCandidate.new(candidate: candidate, profile: profile.to_sym) }
      end
    end

    def configured_fallback_profiles(profile)
      Array(@configuration.profile_fallbacks[profile.to_sym])
        .first(@configuration.maximum_profile_fallbacks)
        .map(&:to_sym)
    end

    def execute_plan(run, request, plan, operation:)
      executions = []
      provider_fallbacks = 0

      plan.each_with_index do |planned, candidate_index|
        break if attempts_exhausted?(executions) || deadline_reached?(request)

        if candidate_index.positive?
          previous = plan[candidate_index - 1]
          if same_profile_provider_fallback?(previous, planned)
            provider_fallbacks += 1
            next if provider_fallbacks > @configuration.maximum_provider_fallbacks
          end
        end

        (@configuration.maximum_retries_per_candidate + 1).times do |retry_index|
          break if attempts_exhausted?(executions) || deadline_reached?(request)

          attempt = create_attempt!(
            run,
            request,
            planned,
            executions.length + 1,
            attempt_kind(executions, retry_index)
          )
          @active_attempt = attempt if operation == :stream
          result = execute_attempt(request, planned.candidate, operation: operation)
          complete_attempt!(attempt, result)
          executions << ExecutedAttempt.new(record: attempt, result: result)
          if result.success? && result.tool_calls.any?
            return execute_custom_tool_rounds(run, request, planned, executions, operation: operation)
          end
          return executions if result.success? || !result.error&.retryable? || @visible_stream_output
          break if retry_index >= @configuration.maximum_retries_per_candidate
          break unless wait_before_retry(request, retry_index)
        end
      end

      executions
    end

    def wait_before_retry(request, retry_index)
      remaining = request.fetch(:execution_deadline) - Time.current
      return false if remaining <= 0

      base = Float(@configuration.retry_backoff_base)
      maximum = Float(@configuration.retry_backoff_max)
      jitter = Float(@configuration.retry_jitter)
      delay = [base * (2**retry_index), maximum].min
      delay *= 1 + (jitter * ((Float(@configuration.retry_random.call) * 2) - 1))
      delay = [[delay, 0].max, maximum].min
      return false if delay >= remaining

      @configuration.retry_sleeper.call(delay) if delay.positive?
      true
    rescue ArgumentError, TypeError
      raise RecordingStudioAI::Errors::ContractValidationError.new(
        "retry backoff configuration is invalid", code: "configuration"
      )
    end

    def deadline_reached?(request)
      Time.current >= request.fetch(:execution_deadline)
    end

    def execute_custom_tool_rounds(run, request, planned, executions, operation:)
      rounds = 0

      while executions.last.result.success? && executions.last.result.tool_calls.any?
        if rounds >= @configuration.maximum_custom_tool_rounds
          executions[-1] = with_custom_tool_failure(executions.last, custom_tool_failure("custom_tool_round_limit"))
          break
        end
        if attempts_exhausted?(executions)
          executions[-1] = with_custom_tool_failure(executions.last, custom_tool_failure("custom_tool_attempt_limit"))
          break
        end

        rounds += 1
        requesting_attempt = executions.last.record
        outcomes = executions.last.result.tool_calls.map do |tool_call|
          execute_custom_tool(run, request, requesting_attempt, tool_call)
        end
        failed_outcome = outcomes.find { |outcome| outcome.fetch(:error) }
        if failed_outcome
          outcomes.reject { |outcome| outcome.fetch(:error) }.each do |outcome|
            complete_custom_tool_invocation!(outcome.fetch(:invocation), outcome.fetch(:result), nil)
            emit_custom_tool_completed(outcome.fetch(:invocation))
          end
          executions[-1] = with_custom_tool_failure(executions.last, failed_outcome.fetch(:error))
          break
        end

        continuation = nil
        RecordingStudioAI::ApplicationRecord.transaction do
          continuation = create_attempt!(run, request, planned, executions.length + 1, "continuation")
          outcomes.each do |outcome|
            complete_custom_tool_invocation!(outcome.fetch(:invocation), outcome.fetch(:result), continuation)
          end
        end
        outcomes.each { |outcome| emit_custom_tool_completed(outcome.fetch(:invocation)) }

        history = Array(request[:custom_tool_history]) + [{
          calls: executions.last.result.tool_calls.map(&:to_h),
          results: outcomes.map { |outcome| outcome.fetch(:provider_result) }
        }]
        continuation_request = request.merge(
          custom_tool_calls: history.last.fetch(:calls),
          custom_tool_results: history.last.fetch(:results),
          custom_tool_history: history
        )
        result = execute_attempt(continuation_request, planned.candidate, operation: operation)
        if result.success? && result.tool_calls.any? && rounds >= @configuration.maximum_custom_tool_rounds
          result = result.with(error: custom_tool_failure("custom_tool_round_limit").error, tool_calls: [])
        end
        complete_attempt!(continuation, result)
        executions << ExecutedAttempt.new(record: continuation, result: result)
        request = continuation_request
      end

      executions
    end

    def execute_custom_tool(run, request, requesting_attempt, tool_call)
      definition = request.fetch(:custom_tool_definitions).find { |item| item.key == tool_call.key }
      return unknown_custom_tool(run, requesting_attempt, tool_call) unless definition

      invocation = create_custom_tool_invocation!(run, requesting_attempt, tool_call, definition)
      emit_stream_event("custom_tool_requested", metadata: stream_tool_metadata(invocation))
      arguments = definition.validate_arguments!(tool_call.arguments)
      authorize_custom_tool!(request, definition, invocation)
      confirm_custom_tool!(request, definition, arguments, invocation)
      invocation.update!(status: "authorized")

      started_at = Time.current
      invocation.update!(status: "running", started_at: started_at)
      emit_stream_event("custom_tool_started", metadata: stream_tool_metadata(invocation))
      context = custom_tool_context(request, run, requesting_attempt)
      @active_cancellation_state = context.cancellation_state
      raise_custom_tool_cancelled! if context.cancellation_state.cancelled?
      result = Timeout.timeout(tool_timeout(request)) do
        definition.executor.call(arguments, context)
      end
      raise_custom_tool_cancelled! if context.cancellation_state.cancelled?
      serializable_result = RecordingStudioAI::Contracts::Containment.ensure_serializable!(
        result,
        path: "custom_tool.result"
      )
      serialized_result = JSON.generate(serializable_result)
      if serialized_result.bytesize > @configuration.maximum_custom_tool_result_size
        raise RecordingStudioAI::Errors::ContractValidationError.new(
          "custom tool result exceeds the configured byte limit",
          code: "custom_tool_result_too_large"
        )
      end

      {
        invocation: invocation,
        result: serializable_result,
        provider_result: {
          provider_tool_call_id: tool_call.provider_tool_call_id,
          tool_key: definition.key,
          result: serializable_result
        },
        error: nil
      }
    rescue RecordingStudioAI::Errors::ContractValidationError => error
      status, category = case error.code
                         when "authorization" then %w[denied custom_tool_denied]
                         when "custom_tool_confirmation_rejected", "custom_tool_confirmation_expired"
                           %w[rejected custom_tool_rejected]
                         when "custom_tool_confirmation_pending" then [nil, "custom_tool_confirmation_required"]
                         when "custom_tool_cancelled" then %w[cancelled cancelled]
                         when "custom_tool_validation" then %w[failed custom_tool_validation]
                         else %w[failed custom_tool_failed]
                         end
      fail_custom_tool_invocation!(invocation, status, category, error.code, error.message) if invocation && status
      { error: custom_tool_failure(error.code, category: category, message: error.message) }
    rescue Timeout::Error
      fail_custom_tool_invocation!(invocation, "failed", "custom_tool_failed", "custom_tool_timeout",
                                   "Custom tool execution timed out.")
      { error: custom_tool_failure("custom_tool_timeout") }
    rescue StandardError
      fail_custom_tool_invocation!(invocation, "failed", "custom_tool_failed", "custom_tool_execution",
                                   "Custom tool execution failed.")
      { error: custom_tool_failure("custom_tool_execution") }
    ensure
      @active_cancellation_state = nil
    end

    def authorize_custom_tool!(request, definition, invocation)
      RecordingStudioAI::Authorization.authorize!(
        :use_custom_tool,
        attribution: request.fetch(:attribution),
        context: custom_tool_authorization_context(definition, invocation)
      )
    end

    def confirm_custom_tool!(request, definition, arguments, invocation)
      unless definition.requires_confirmation || definition.destructive
        invocation.update!(confirmation_status: "not_required")
        return
      end

      invocation.update!(status: "awaiting_confirmation", confirmation_status: "pending")
      RecordingStudioAI::Authorization.authorize!(
        :confirm_custom_tool,
        attribution: request.fetch(:attribution),
        context: custom_tool_authorization_context(definition, invocation)
      )
      outcome = normalize_confirmation_outcome(@configuration.custom_tool_confirmation_handler.call(
        definition: definition,
        arguments: arguments,
        context: custom_tool_context(request, invocation.run, invocation.requested_by_attempt)
      ))
      if outcome == :approved
        attribution = request.fetch(:attribution)
        confirmer = attribution.initiator
        return invocation.update!(
          confirmation_status: "confirmed",
          confirmed_by_type: confirmer.class.name,
          confirmed_by_id: identifier(confirmer),
          confirmed_at: Time.current
        )
      end

      if outcome == :pending
        invocation.update!(
          error_category: "custom_tool_confirmation_required",
          error_code: "custom_tool_confirmation_pending",
          error_message: "Custom tool confirmation is pending."
        )
        raise RecordingStudioAI::Errors::ContractValidationError.new(
          "Custom tool confirmation is pending.", code: "custom_tool_confirmation_pending"
        )
      end

      confirmation_status = outcome == :expired ? "expired" : "rejected"
      error_code = outcome == :expired ? "custom_tool_confirmation_expired" : "custom_tool_confirmation_rejected"
      invocation.update!(
        status: "rejected",
        confirmation_status: confirmation_status,
        completed_at: Time.current,
        error_category: "custom_tool_rejected",
        error_code: error_code,
        error_message: "Custom tool confirmation was #{confirmation_status}."
      )
      raise RecordingStudioAI::Errors::ContractValidationError.new(
        "Custom tool confirmation was #{confirmation_status}.", code: error_code
      )
    end

    def normalize_confirmation_outcome(value)
      return :approved if value == true || %w[approved confirmed].include?(value.to_s)
      return :rejected if value == false || value.nil? || value.to_s == "rejected"
      return value.to_sym if %w[pending expired].include?(value.to_s)

      raise RecordingStudioAI::Errors::ContractValidationError.new(
        "custom tool confirmation handler returned an invalid outcome", code: "configuration"
      )
    end

    def raise_custom_tool_cancelled!
      raise RecordingStudioAI::Errors::ContractValidationError.new(
        "Custom tool execution was cancelled.", code: "custom_tool_cancelled"
      )
    end

    def create_custom_tool_invocation!(run, requesting_attempt, tool_call, definition)
      serialized_arguments = JSON.generate(tool_call.arguments)
      registered_names = definition.parameters.map { |parameter| parameter.fetch(:name) }
      recognized_names = tool_call.arguments.keys & registered_names
      run.custom_tool_invocations.create!(
        requested_by_attempt: requesting_attempt,
        provider_tool_call_id: tool_call.provider_tool_call_id,
        tool_key: definition.key,
        tool_version: definition.version,
        tool_name_snapshot: definition.name,
        status: "requested",
        read_only: definition.read_only,
        destructive: definition.destructive,
        requires_confirmation: definition.requires_confirmation,
        idempotent: definition.idempotent,
        cost_category: definition.cost,
        latency_category: definition.latency,
        arguments_digest: digest(serialized_arguments),
        arguments_summary: JSON.generate(
          parameter_count: tool_call.arguments.length,
          recognized_parameters: recognized_names.sort,
          byte_size: serialized_arguments.bytesize
        ),
        metadata: {}
      )
    end

    def complete_custom_tool_invocation!(invocation, result, continuation)
      completed_at = Time.current
      serialized_result = JSON.generate(result)
      invocation.update!(
        status: "completed",
        continued_by_attempt: continuation,
        result_digest: digest(serialized_result),
        result_summary: JSON.generate(type: result.class.name, byte_size: serialized_result.bytesize),
        completed_at: completed_at,
        latency_ms: elapsed_ms(invocation.started_at, completed_at)
      )
    end

    def emit_custom_tool_completed(invocation)
      emit_stream_event("custom_tool_completed", metadata: stream_tool_metadata(invocation))
    end

    def fail_custom_tool_invocation!(invocation, status, category, code, message)
      return if RecordingStudioAI::CustomToolInvocation.terminal_statuses.include?(invocation.status)

      completed_at = Time.current
      invocation.update!(
        status: status,
        completed_at: completed_at,
        latency_ms: invocation.started_at ? elapsed_ms(invocation.started_at, completed_at) : nil,
        error_category: category,
        error_code: code,
        error_message: message
      )
    end

    def unknown_custom_tool(run, requesting_attempt, tool_call)
      invocation = run.custom_tool_invocations.create!(
        requested_by_attempt: requesting_attempt,
        provider_tool_call_id: tool_call.provider_tool_call_id,
        tool_key: tool_call.key,
        tool_version: 0,
        tool_name_snapshot: tool_call.key,
        status: "failed",
        read_only: false,
        destructive: false,
        requires_confirmation: false,
        idempotent: false,
        arguments_digest: digest(JSON.generate(tool_call.arguments)),
        arguments_summary: JSON.generate(parameter_count: tool_call.arguments.length),
        completed_at: Time.current,
        error_category: "custom_tool_not_found",
        error_code: "custom_tool_not_found",
        error_message: "Provider requested an unavailable custom tool.",
        metadata: {}
      )
      {
        invocation: invocation,
        error: custom_tool_failure(
          "custom_tool_not_found",
          category: "custom_tool_not_found",
          message: "Provider requested an unavailable custom tool."
        )
      }
    end

    def custom_tool_context(request, run, requesting_attempt)
      attribution = request.fetch(:attribution)
      CustomToolContext.new(
        root_recording: attribution.root_recording,
        context_recording: attribution.context_recording,
        initiator: attribution.initiator,
        executor: attribution.executor,
        run: run,
        requesting_attempt: requesting_attempt,
        execution_source: attribution.execution_source,
        deadline: request.fetch(:execution_deadline),
        cancellation_state: CancellationState.new(deadline: request.fetch(:execution_deadline))
      )
    end

    def custom_tool_authorization_context(definition, invocation)
      {
        tool_key: definition.key,
        tool_version: definition.version,
        invocation_id: invocation.id,
        read_only: definition.read_only,
        destructive: definition.destructive,
        requires_confirmation: definition.requires_confirmation
      }
    end

    def custom_tool_failure(code, category: "custom_tool_failed", message: "Custom tool execution failed.")
      RecordingStudioAI::Adapters::Result.new(
        error: RecordingStudioAI::Contracts::NormalizedError.new(
          category: category,
          code: code,
          message: message,
          retryable: false
        )
      )
    end

    def with_custom_tool_failure(execution, failure)
      execution.with(result: execution.result.with(error: failure.error, tool_calls: []))
    end

    def same_profile_provider_fallback?(previous, current)
      previous.profile == current.profile && previous.candidate.provider != current.candidate.provider
    end

    def attempts_exhausted?(executions)
      executions.length >= @configuration.maximum_attempts
    end

    def attempt_kind(executions, retry_index)
      return "primary" if executions.empty?
      return "retry" if retry_index.positive?

      "fallback"
    end

    def execute_attempt(request, candidate, operation:)
      buffer_stream_events = operation == :stream && request[:schema]
      @stream_event_buffer = [] if buffer_stream_events
      timeout, timeout_error = provider_timeout(request)
      result = Timeout.timeout(timeout, timeout_error) do
        if operation == :stream
          execute_stream_adapter(request, candidate)
        else
          adapter_for!(candidate).generate(request: request, candidate: candidate)
        end
      end
      unless result.is_a?(RecordingStudioAI::Adapters::Result)
        raise TypeError, "Adapter must return RecordingStudioAI::Adapters::Result"
      end
      result = RecordingStudioAI::CostCalculator.apply(
        result, provider: candidate.provider, model: candidate.model, configuration: @configuration
      )

      if result.tool_calls.empty?
        result = RecordingStudioAI::StructuredOutput.apply(
          result, schema: request[:schema], provider: candidate.provider
        )
      end
      flush_stream_event_buffer if buffer_stream_events && result.success?
      result
    rescue StreamConsumerError
      raise
    rescue StreamIdleTimeout
      RecordingStudioAI::Adapters::Result.new(
        error: RecordingStudioAI::Contracts::NormalizedError.new(
          category: "timeout",
          code: "stream_idle_timeout",
          message: "AI stream exceeded its configured idle timeout.",
          retryable: false,
          provider: candidate.provider.to_s
        )
      )
    rescue ProviderRequestTimeout
      RecordingStudioAI::Adapters::Result.new(
        error: RecordingStudioAI::Contracts::NormalizedError.new(
          category: "timeout",
          code: "provider_timeout",
          message: "AI provider request exceeded its configured timeout.",
          retryable: true,
          provider: candidate.provider.to_s
        )
      )
    rescue Timeout::Error
      RecordingStudioAI::Adapters::Result.new(
        error: RecordingStudioAI::Contracts::NormalizedError.new(
          category: "timeout",
          code: "execution_deadline_exceeded",
          message: "AI execution exceeded its configured deadline.",
          retryable: false,
          provider: candidate.provider.to_s
        )
      )
    rescue StandardError
      RecordingStudioAI::Adapters::Result.new(
        error: RecordingStudioAI::Contracts::NormalizedError.new(
          category: "provider_error",
          code: "adapter_error",
          message: "Adapter execution failed.",
          retryable: false,
          provider: candidate.provider.to_s
        )
      )
    ensure
      @stream_event_buffer = nil if buffer_stream_events
    end

    def execute_stream_adapter(request, candidate)
      messages = SizedQueue.new(1)
      worker = Thread.new do
        result = adapter_for!(candidate).stream(request: request, candidate: candidate) do |event|
          messages << [:event, event]
        end
        messages << [:result, result]
      rescue StandardError => e
        messages << [:error, e]
      end

      loop do
        type, payload = Timeout.timeout(stream_idle_timeout(request), StreamIdleTimeout) { messages.pop }
        emit_adapter_stream_event(payload) if type == :event
        return payload if type == :result
        raise payload if type == :error
      end
    ensure
      worker&.kill
      worker&.join(0.1)
    end

    def provider_timeout(request)
      remaining = remaining_execution_time(request)
      request_timeout = @configuration.request_timeout
      return [request_timeout, ProviderRequestTimeout] if request_timeout < remaining

      [remaining, Timeout::Error]
    end

    def tool_timeout(request)
      [remaining_execution_time(request), @configuration.custom_tool_timeout].min
    end

    def stream_idle_timeout(request)
      [remaining_execution_time(request), @configuration.stream_idle_timeout].min
    end

    def remaining_execution_time(request)
      remaining = request.fetch(:execution_deadline) - Time.current
      raise Timeout::Error if remaining <= 0

      remaining
    end

    def adapter_for!(candidate)
      @configuration.adapters.fetch(candidate.provider) do
        raise RecordingStudioAI::Errors::ContractValidationError.new(
          "No adapter is configured for #{candidate.provider}",
          code: "configuration"
        )
      end
    end

    def create_run!(request, candidate, operation:)
      attribution = request[:attribution]
      input = request_input(request)
      attachment_metadata = RecordingStudioAI::Attachments.metadata(request[:attachments])
      RecordingStudioAI::Run.create!(
        operation: operation.to_s,
        purpose: request[:purpose],
        status: "running",
        profile_key: request[:profile],
        requested_provider: request[:provider],
        resolved_provider: candidate.provider,
        resolved_model: candidate.model,
        root_recording_id: identifier(attribution.root_recording),
        context_recording_id: identifier(attribution.context_recording),
        initiator_type: attribution.initiator.class.name,
        initiator_id: identifier(attribution.initiator),
        initiator_kind: attribution.initiator_kind,
        initiator_snapshot: attribution.snapshot(:initiator, configuration: @configuration),
        executor_type: attribution.executor&.class&.name,
        executor_id: identifier(attribution.executor),
        executor_snapshot: attribution.snapshot(:executor, configuration: @configuration),
        impersonator_type: attribution.impersonator&.class&.name,
        impersonator_id: identifier(attribution.impersonator),
        impersonator_snapshot: attribution.snapshot(:impersonator, configuration: @configuration),
        execution_source: attribution.execution_source,
        request_id: attribution.request_id,
        job_id: attribution.job_id,
        correlation_id: SecureRandom.uuid,
        started_at: Time.current,
        input_digest: digest(input),
        input_character_count: input.length,
        **attachment_metadata,
        web_search_requested: request[:provider_native_tools].include?(:web_search),
        metadata: request[:metadata]
      )
    end

    def create_attempt!(run, request, planned, sequence, kind)
      attachment_metadata = RecordingStudioAI::Attachments.metadata(request[:attachments])
      run.attempts.create!(
        sequence: sequence,
        kind: kind,
        status: "running",
        profile_key: planned.profile,
        provider: planned.candidate.provider,
        model: planned.candidate.model,
        streaming: run.operation == "stream",
        **attachment_metadata,
        provider_file_count: %i[openai gemini].include?(planned.candidate.provider) ? 0 : nil,
        web_search_requested: request[:provider_native_tools].include?(:web_search),
        started_at: Time.current
      )
    end

    def complete_attempt!(attempt, result)
      completed_at = Time.current
      attempt.update!(persistence_metrics(result).merge(
                        status: result.success? ? "completed" : "failed",
                        provider_request_id: result.provider_request_id,
                        finish_reason: result.finish_reason,
                        retryable: result.error&.retryable?,
                        web_search_used: result.provider_native_tools.include?("web_search"),
                        citation_count: result.citations.length,
                        completed_at: completed_at,
                        latency_ms: elapsed_ms(attempt.started_at, completed_at),
                        error_category: result.error&.category,
                        error_code: result.error&.code,
                        error_message: result.error&.message,
                        metadata: result.metadata
                      ))
      RecordingStudioAI::Retention.retain_attempt!(attempt, result, configuration: @configuration)
    end

    def complete_run!(run, executions, final_execution)
      completed_at = Time.current
      final_result = final_execution.result
      final_attempt = final_execution.record
      usage = aggregate_usage(executions)
      cost = aggregate_cost(executions)
      run.update!(persistence_metrics_for(usage, cost).merge(
                    status: final_result.success? ? "completed" : "failed",
                    resolved_provider: final_attempt.provider,
                    resolved_model: final_attempt.model,
                    attempt_count: executions.length,
                    retry_count: executions.count { |execution| execution.record.kind == "retry" },
                    fallback_count: executions.count { |execution| execution.record.kind == "fallback" },
                    custom_tool_invocation_count: custom_tool_invocation_count(run),
                    completed_at: completed_at,
                    latency_ms: elapsed_ms(run.started_at, completed_at),
                    output_digest: digest(final_result.text),
                    output_character_count: final_result.text&.length,
                    web_search_used: executions.any? do |execution|
                      execution.result.provider_native_tools.include?("web_search")
                    end,
                    citation_count: executions.sum { |execution| execution.result.citations.length },
                    error_category: final_result.error&.category,
                    error_code: final_result.error&.code,
                    error_message: final_result.error&.message
                  ))
    end

    def complete_deadline_failure(request, run, operation:)
      error = RecordingStudioAI::Contracts::NormalizedError.new(
        category: "timeout",
        code: "execution_deadline_exceeded",
        message: "AI execution exceeded its configured deadline.",
        retryable: false,
        provider: run.resolved_provider
      )
      completed_at = Time.current
      run.update!(
        status: "failed",
        attempt_count: 0,
        completed_at: completed_at,
        latency_ms: elapsed_ms(run.started_at, completed_at),
        error_category: error.category,
        error_code: error.code,
        error_message: error.message
      )
      RecordingStudioAI::Contracts::GenerationResponse.new(
        operation: operation.to_s,
        purpose: request[:purpose],
        profile: request[:profile],
        provider: run.resolved_provider,
        model: run.resolved_model,
        run: run,
        attempts: [],
        error: error,
        metadata: request[:metadata]
      )
    end

    def aggregate_usage(executions)
      usages = executions.filter_map { |execution| execution.result.usage }
      return nil if usages.empty?

      values = RecordingStudioAI::Contracts::Usage::TOKEN_FIELDS.to_h do |field|
        reported = usages.map { |usage| usage.public_send(field) }
        [field, reported.any?(&:nil?) ? nil : reported.sum]
      end
      RecordingStudioAI::Contracts::Usage.new(**values)
    end

    def aggregate_cost(executions)
      costs = executions.map { |execution| execution.result.cost }
      return nil if costs.empty? || costs.any?(&:nil?)

      currencies = costs.map(&:currency).uniq
      return nil unless currencies.one?

      RecordingStudioAI::Contracts::Cost.new(
        amount: costs.sum(&:amount),
        currency: currencies.first,
        estimated: costs.any?(&:estimated?),
        source: costs.map(&:source).uniq.one? ? costs.first.source : "estimate"
      )
    end

    def persistence_metrics(result)
      persistence_metrics_for(result.usage, result.cost).merge(cost_source: result.cost&.source)
    end

    def persistence_metrics_for(usage, cost)
      {
        input_tokens: usage&.input_tokens,
        output_tokens: usage&.output_tokens,
        total_tokens: usage&.total_tokens,
        cached_input_tokens: usage&.cached_input_tokens,
        reasoning_tokens: usage&.reasoning_tokens,
        cost_amount_microunits: cost&.amount,
        cost_currency: cost&.currency,
        cost_estimated: cost&.estimated?
      }
    end

    def build_response(request, run, executions, final_execution, operation:)
      final_result = final_execution.result
      final_attempt = final_execution.record
      RecordingStudioAI::Contracts::GenerationResponse.new(
        operation: operation.to_s,
        purpose: request[:purpose],
        profile: request[:profile],
        provider: final_attempt.provider,
        model: final_attempt.model,
        run: run,
        usage: aggregate_usage(executions),
        cost: aggregate_cost(executions),
        attempts: executions.map { |execution| attempt_summary(execution) },
        error: final_result.error,
        metadata: request[:metadata],
        text: final_result.text,
        structured_data: final_result.structured_data,
        citations: final_result.citations,
        provider_native_tools: final_result.provider_native_tools,
        custom_tool_invocations: custom_tool_invocation_summaries(run),
        finish_reason: final_result.finish_reason
      )
    end

    def build_resolution_failure(request, error, operation:)
      RecordingStudioAI::Contracts::GenerationResponse.new(
        operation: operation.to_s,
        purpose: request[:purpose],
        profile: request[:profile],
        attempts: [],
        error: RecordingStudioAI::Contracts::NormalizedError.new(
          category: error.category,
          code: error.code,
          message: error.message,
          retryable: false,
          provider: request[:provider]&.to_s
        ),
        metadata: request[:metadata]
      )
    end

    def attempt_summary(execution)
      attempt = execution.record
      result = execution.result
      RecordingStudioAI::Contracts::AttemptSummary.new(
        sequence: attempt.sequence,
        kind: attempt.kind,
        provider: attempt.provider,
        model: attempt.model,
        status: attempt.status,
        usage: result.usage,
        cost: result.cost,
        latency: attempt.latency_ms,
        finish_reason: attempt.finish_reason,
        error: attempt.completed? ? nil : result.error
      )
    end

    def custom_tool_invocation_summaries(run)
      return [] unless defined?(RecordingStudioAI::CustomToolInvocation)

      run.custom_tool_invocations.order(:id).map do |invocation|
        {
          id: invocation.id,
          provider_tool_call_id: invocation.provider_tool_call_id,
          tool_key: invocation.tool_key,
          tool_version: invocation.tool_version,
          status: invocation.status,
          confirmation_status: invocation.confirmation_status,
          error_category: invocation.error_category,
          error_code: invocation.error_code
        }
      end
    end

    def custom_tool_invocation_count(run)
      return 0 unless defined?(RecordingStudioAI::CustomToolInvocation)

      run.custom_tool_invocations.count
    end

    def emit_adapter_stream_event(event)
      unless event.is_a?(RecordingStudioAI::Adapters::StreamEvent)
        raise TypeError, "Adapter must yield RecordingStudioAI::Adapters::StreamEvent"
      end

      return @stream_event_buffer << event if @stream_event_buffer

      deliver_adapter_stream_event(event)
    end

    def flush_stream_event_buffer
      events = @stream_event_buffer
      @stream_event_buffer = nil
      events.each { |event| deliver_adapter_stream_event(event) }
    end

    def deliver_adapter_stream_event(event)
      emit_stream_event(
        event.type,
        text_delta: event.text_delta,
        citation: event.citation,
        metadata: event.metadata
      )
    end

    def emit_final_stream_events(response)
      unless response.success?
        emit_stream_event("error", error: response.error, metadata: response.metadata)
        return
      end

      emit_stream_event("usage", usage: response.usage) if response.usage
      emit_stream_event("completed", metadata: response.metadata)
    end

    def emit_stream_event(type, **attributes)
      return unless @event_handler

      @event_handler.call(RecordingStudioAI::Contracts::StreamingEvent.new(type: type, **attributes))
      @visible_stream_output = true
    rescue StreamConsumerError
      raise
    rescue StandardError => error
      raise StreamConsumerError.new(error)
    end

    def cancel_active_stream_records!
      @active_cancellation_state&.cancel!
      completed_at = Time.current
      running_attempts = @active_run ? @active_run.attempts.where(status: "running") : Array(@active_attempt).select { |attempt| attempt.status == "running" }
      running_attempts.each do |attempt|
        attempt.update!(
          status: "cancelled",
          completed_at: completed_at,
          latency_ms: elapsed_ms(attempt.started_at, completed_at),
          retryable: false,
          error_category: "cancelled",
          error_code: "stream_cancelled",
          error_message: "Stream consumption was cancelled."
        )
      end
      if @active_run&.status == "running"
        @active_run.update!(
          status: "cancelled",
          completed_at: completed_at,
          latency_ms: elapsed_ms(@active_run.started_at, completed_at),
          error_category: "cancelled",
          error_code: "stream_cancelled",
          error_message: "Stream consumption was cancelled."
        )
      end

      return unless @active_run && defined?(RecordingStudioAI::CustomToolInvocation)

      @active_run.custom_tool_invocations.find_each do |invocation|
        fail_custom_tool_invocation!(
          invocation,
          "cancelled",
          "cancelled",
          "stream_cancelled",
          "Stream consumption was cancelled."
        )
      end
    end

    def stream_tool_metadata(invocation)
      {
        invocation_id: invocation.id,
        provider_tool_call_id: invocation.provider_tool_call_id,
        tool_key: invocation.tool_key,
        tool_version: invocation.tool_version,
        status: invocation.status
      }
    end

    def identifier(value)
      value && value.respond_to?(:id) ? value.id : nil
    end

    def elapsed_ms(started_at, completed_at)
      ((completed_at - started_at) * 1000).round
    end

    def request_input(request)
      parts = [request[:system_instruction], request[:prompt]]
      parts.concat(Array(request[:messages]).filter_map { |message| message[:content] || message["content"] })
      parts.compact.join("\n")
    end

    def digest(value)
      Digest::SHA256.hexdigest(value) unless value.nil?
    end
  end
end
