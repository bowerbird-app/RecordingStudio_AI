# frozen_string_literal: true

module RecordingStudioAI
  module Usage
    DECLINED_CATEGORY = "usage"
    DECLINED_CODE = "usage_declined"
    MESSAGE_LIMIT = 255

    module_function

    def precheck!(attribution:)
      return unless billing?

      checker = RecordingStudioAI.configuration.usage_precheck
      require_precheck!(checker)
      minimum = RecordingStudioAI.configuration.minimum_credit_balance
      return if checker.call(attribution: attribution, minimum: minimum) == true

      request_error!("Not enough credits for this call.")
    end

    def charge_attempt!(attempt:, result:, request:, operation:)
      charge!(
        subject: attempt,
        label: "attempt",
        counts: counts_for(result, operation),
        provider: attempt.provider,
        model: attempt.model,
        prompt: request[:prompt_definition],
        tools: request[:custom_tool_definitions],
        idempotency_key: "ai-attempt:#{attempt.id}",
        attribution: request[:attribution] || request.fetch(:attribution)
      )
    end

    def charge_batch_item!(item:, result:, batch:, attribution:)
      charge!(
        subject: item,
        label: "batch item",
        counts: counts_for(result, :generation),
        provider: batch.provider,
        model: batch.model,
        prompt: nil,
        tools: [],
        idempotency_key: "ai-batch-item:#{item.id}",
        attribution: attribution
      )
    end

    def charge_hosted_agent_turn!(run:, usage:, attribution:)
      charge!(
        subject: run,
        label: "run",
        counts: usage&.counts || {},
        provider: run.resolved_provider,
        model: run.resolved_model,
        prompt: nil,
        tools: [],
        idempotency_key: "ai-hosted-agent-turn:#{run.provider_turn_id}",
        attribution: attribution
      )
    end

    def charge!(subject:, label:, counts:, provider:, model:, prompt:, tools:, idempotency_key:, attribution:)
      return unless billing?

      require_id!(subject, label)
      quote = Credits.quote(
        counts: counts, provider: provider, model: model, prompt: prompt, tools: tools
      )
      return if quote.nil?

      RecordingStudioAI.configuration.usage_handler.call(
        credits: quote.credits,
        breakdown: quote.breakdown,
        idempotency_key: idempotency_key,
        attribution: attribution
      )
      quote
    end

    def counts_for(result, operation)
      usage = result&.usage
      counts = usage.nil? ? {} : usage.counts.dup
      count_successful_decision!(counts, result) if operation.to_sym == :decision
      counts
    end

    def count_successful_decision!(counts, result)
      return unless result&.success?

      counts[:decision] = counts.fetch(:decision, 0).to_i + 1
    end

    def record_charge_failure!(run, error)
      return unless run&.status == "running"

      run.update!(
        status: "failed",
        error_category: DECLINED_CATEGORY,
        error_code: "usage_charge_failed",
        error_message: error.message.to_s[0, MESSAGE_LIMIT],
        **Orchestration::Support.completion_clock(run.started_at)
      )
    rescue StandardError
      nil
    end

    def billing?
      !RecordingStudioAI.configuration.usage_handler.nil?
    end

    def require_precheck!(checker)
      return if checker.respond_to?(:call)

      configuration_error!("usage_handler requires a usage_precheck that responds to call")
    end

    def require_id!(subject, label)
      return if subject.id

      request_error!("#{label} id is required")
    end

    def configuration_error!(message)
      raise RecordingStudioAI::Errors::ContractValidationError.new(message, code: "configuration")
    end

    def request_error!(message)
      raise RecordingStudioAI::Errors::ContractValidationError.new(message, code: "invalid_request")
    end

    private_class_method :charge!, :counts_for, :count_successful_decision!, :billing?,
                         :require_precheck!, :require_id!, :configuration_error!, :request_error!
  end
end
