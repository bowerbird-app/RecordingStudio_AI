# frozen_string_literal: true

require "securerandom"

module RecordingStudioAI
  class BatchOrchestrator
    def initialize(configuration: RecordingStudioAI.configuration)
      @configuration = configuration
      @resolver = Resolver.new(configuration: configuration)
    end

    def submit(request)
      candidate = @resolver.resolve(
        profile: request.fetch(:profile),
        provider: request[:provider],
        model: request[:model],
        required_capabilities: Capabilities.for_batch(request.fetch(:items))
      )
      batch = create_records!(request, candidate)
      result = provider_for!(candidate).submit_batch(request: request, candidate: candidate)
      ensure_batch_result!(result)
      result = normalize_submission_result(result, candidate)
      result = apply_result!(batch, result, fail_pending_items: !result.success?)
      build_response(batch, result, operation: "batch_submit", transient_items: result.items)
    rescue Errors::ResolutionError => e
      resolution_failure(request, e)
    rescue StandardError => e
      raise unless batch

      result = submission_failure(e, candidate)
      apply_result!(batch, result, fail_pending_items: true)
      build_response(batch, result, operation: "batch_submit")
    end

    def refresh(request)
      batch = find_batch!(request)
      candidate = stored_candidate!(batch, cancellation: false)
      result = provider_for!(candidate).refresh_batch(batch: batch, candidate: candidate)
      ensure_batch_result!(result)
      result = apply_result!(batch, result)
      build_response(batch.reload, result, operation: "batch_refresh", transient_items: result.items)
    end

    def cancel(request)
      batch = find_batch!(request)
      candidate = stored_candidate!(batch, cancellation: true)
      result = provider_for!(candidate).cancel_batch(batch: batch, candidate: candidate)
      ensure_batch_result!(result)
      result = apply_result!(batch, result)
      build_response(batch.reload, result, operation: "batch_cancel", transient_items: result.items)
    rescue Errors::ResolutionError => e
      build_response(batch, error_result(e, batch&.provider), operation: "batch_cancel")
    end

    private

    def create_records!(request, candidate)
      attribution = request.fetch(:attribution)
      Batch.transaction do
        batch = Batch.create!(
          status: "preparing", profile_key: request.fetch(:profile), provider: candidate.provider,
          model: candidate.model, root_recording_id: identifier(attribution.root_recording),
          context_recording_id: identifier(attribution.context_recording),
          initiator_type: attribution.initiator.class.name, initiator_id: identifier(attribution.initiator),
          initiator_kind: attribution.initiator_kind,
          executor_type: attribution.executor&.class&.name, executor_id: identifier(attribution.executor),
          impersonator_type: attribution.impersonator&.class&.name,
          impersonator_id: identifier(attribution.impersonator),
          execution_source: attribution.execution_source,
          request_id: attribution.request_id, job_id: attribution.job_id,
          item_count: request.fetch(:items).length,
          metadata: request.fetch(:metadata).merge(
            "_recording_studio_ai" => { "capabilities" => candidate.capabilities.map(&:to_s) }
          )
        )
        request.fetch(:items).each_with_index do |item, position|
          run = Run.create!(
            operation: "batch", purpose: item[:purpose], status: "pending", profile_key: request.fetch(:profile),
            requested_provider: request[:provider], resolved_provider: candidate.provider, resolved_model: candidate.model,
            root_recording_id: identifier(attribution.root_recording),
            context_recording_id: identifier(attribution.context_recording),
            initiator_type: attribution.initiator.class.name, initiator_id: identifier(attribution.initiator),
            initiator_kind: attribution.initiator_kind,
            executor_type: attribution.executor&.class&.name, executor_id: identifier(attribution.executor),
            impersonator_type: attribution.impersonator&.class&.name,
            impersonator_id: identifier(attribution.impersonator),
            execution_source: attribution.execution_source,
            request_id: attribution.request_id, job_id: attribution.job_id,
            attachment_count: item[:attachments].length,
            attachment_total_bytes: item[:attachments].sum { |attachment| attachment[:byte_size] },
            attachment_content_types: item[:attachments].map { |attachment| attachment[:content_type] }.uniq,
            web_search_requested: item[:provider_native_tools].include?(:web_search), metadata: item[:metadata]
          )
          batch.batch_items.create!(
            run: run, position: position, reference: item.fetch(:reference), status: "pending",
            metadata: { "structured_output" => !item[:schema].nil?, "schema" => item[:schema] }.compact
          )
        end
        batch
      end
    end

    def apply_result!(batch, result, fail_pending_items: false)
      accepted_items = []
      Batch.transaction do
        batch.lock!
        result.items.each do |item_result|
          applied = apply_item_result!(batch, item_result)
          accepted_items << applied if applied
        end
        fail_pending_items!(batch, result.error) if fail_pending_items
        terminalize_unresolved_items!(batch, result) if %w[completed cancelled expired failed].include?(result.status)
        update_batch!(batch, result)
      end
      result.with(items: accepted_items)
    end

    def terminalize_unresolved_items!(batch, result)
      item_status = if result.status == "expired"
                      "expired"
                    else
                      (result.status == "cancelled" ? "cancelled" : "failed")
                    end
      error = result.error
      if result.status == "completed"
        error = Contracts::NormalizedError.new(
          category: "invalid_response", code: "missing_batch_item_result",
          message: "Provider completed the batch without returning an item result.",
          retryable: false, provider: batch.provider
        )
      end
      batch.batch_items.each do |item|
        next if BatchItem.terminal_statuses.include?(item.status)

        apply_item_result!(batch, Providers::BatchItemResult.new(
                                    reference: item.reference, status: item_status, error: error
                                  ))
      end
    end

    def apply_item_result!(batch, result)
      item = batch.batch_items.find_by(reference: result.reference)
      item ||= batch.batch_items.find_by(provider_item_id: result.provider_item_id) if result.provider_item_id
      return unless item

      result = CostCalculator.apply(
        result, provider: batch.provider, model: batch.model, configuration: @configuration
      )
      result = validate_structured_result(item, result, batch.provider)
      if BatchItem.terminal_statuses.include?(item.status)
        return result if result.status == item.status

        return
      end
      return if item_status_rank(result.status) < item_status_rank(item.status)

      transition_at = Time.current
      completed_at = result.terminal? ? transition_at : nil
      item.update!(metrics(result).merge(
                     status: result.status, provider_item_id: result.provider_item_id,
                     started_at: item.started_at || (transition_at if result.status != "pending"),
                     completed_at: completed_at, finish_reason: result.finish_reason,
                     error_category: result.error&.category, error_code: result.error&.code,
                     error_message: result.error&.message,
                     metadata: item.metadata.merge(result.metadata)
                   ))
      update_run_from_item!(item.run, result, completed_at)
      Retention.retain_batch_item!(item, result, configuration: @configuration) if result.terminal?
      result
    end

    def update_run_from_item!(run, result, completed_at)
      return if Run.terminal_statuses.include?(run.status)

      run_status = { "pending" => "pending", "processing" => "running", "completed" => "completed",
                     "failed" => "failed", "cancelled" => "cancelled", "expired" => "cancelled" }.fetch(result.status)
      run.update!(metrics(result).merge(
                    status: run_status, started_at: run.started_at || (if run_status != "pending"
                                                                         completed_at || Time.current
                                                                       end),
                    completed_at: completed_at, attempt_count: 0,
                    output_character_count: result.text&.length,
                    web_search_used: result.provider_native_tools.include?("web_search"),
                    citation_count: result.citations.length, error_category: result.error&.category,
                    error_code: result.error&.code, error_message: result.error&.message
                  ))
    end

    def fail_pending_items!(batch, error)
      batch.batch_items.each do |item|
        next if BatchItem.terminal_statuses.include?(item.status)

        normalized = Providers::BatchItemResult.new(
          reference: item.reference, status: "failed",
          error: Contracts::NormalizedError.new(
            category: "batch_submission", code: error&.code || "batch_submission_failed",
            message: "Provider batch submission failed.", retryable: false, provider: batch.provider
          )
        )
        apply_item_result!(batch, normalized)
      end
    end

    def update_batch!(batch, result)
      items = batch.batch_items.reload
      status = aggregate_status(result.status, items)
      status = batch.status if batch_status_rank(status) < batch_status_rank(batch.status)
      attributes = aggregate_metrics(items).merge(
        status: status, provider_batch_id: result.provider_batch_id || batch.provider_batch_id,
        submitted_at: batch.submitted_at || (Time.current unless status == "preparing"),
        completed_at: Batch.terminal_statuses.include?(status) ? Time.current : nil,
        expires_at: result.expires_at || batch.expires_at,
        completed_item_count: items.count(&:completed?), failed_item_count: items.count(&:failed?),
        cancelled_item_count: items.count { |item| item.cancelled? || item.expired? },
        error_category: result.error&.category, error_code: result.error&.code,
        error_message: result.error&.message,
        metadata: batch.metadata.merge(result.metadata)
      )
      return if Batch.terminal_statuses.include?(batch.status)

      batch.update!(attributes)
    end

    def aggregate_status(provider_status, items)
      return "partially_completed" if provider_status == "completed" && items.any? { |item| !item.completed? }

      provider_status
    end

    def item_status_rank(status)
      { "pending" => 0, "processing" => 1, "completed" => 2, "failed" => 2, "cancelled" => 2, "expired" => 2 }
        .fetch(status)
    end

    def batch_status_rank(status)
      {
        "preparing" => 0, "submitted" => 1, "processing" => 2, "completed" => 3,
        "partially_completed" => 3, "failed" => 3, "cancelled" => 3, "expired" => 3
      }.fetch(status)
    end

    def aggregate_metrics(items)
      Contracts::Usage::TOKEN_FIELDS.to_h do |field|
        values = items.map { |item| item.public_send(field) }
        [field, values.empty? || values.any?(&:nil?) ? nil : values.sum]
      end
    end

    def metrics(result)
      {
        input_tokens: result.usage&.input_tokens, output_tokens: result.usage&.output_tokens,
        total_tokens: result.usage&.total_tokens, cached_input_tokens: result.usage&.cached_input_tokens,
        reasoning_tokens: result.usage&.reasoning_tokens
      }
    end

    def validate_structured_result(item, result, provider)
      schema = item.metadata&.fetch("schema", nil)
      return result unless schema && result.status == "completed"

      validated = StructuredOutput.apply(
        Providers::Result.new(text: result.text), schema: schema, provider: provider
      )
      if validated.success?
        result.with(structured_data: validated.structured_data)
      else
        result.with(status: "failed", structured_data: nil, error: validated.error)
      end
    end

    def find_batch!(request)
      Batch.find_by!(id: request.fetch(:batch_id),
                     root_recording_id: identifier(request.fetch(:attribution).root_recording))
    rescue ActiveRecord::RecordNotFound
      raise Errors::ContractValidationError.new("batch was not found in the requested root", code: "invalid_request")
    end

    def stored_candidate!(batch, cancellation:)
      required = [:provider_batch]
      required << :provider_batch_cancellation if cancellation
      capabilities = batch.metadata.dig("_recording_studio_ai", "capabilities") || []
      candidate = Candidate.new(provider: batch.provider, model: batch.model, capabilities: capabilities)
      return candidate if @configuration.providers.key?(candidate.provider) && candidate.supports?(required)

      raise Errors::ResolutionError.new(
        category: "unsupported_capability", code: "unsupported_capability",
        message: "Stored provider batch does not support #{required.join(', ')}."
      )
    end

    def provider_for!(candidate) = @configuration.providers.fetch(candidate.provider)

    def ensure_batch_result!(result)
      return if result.is_a?(Providers::BatchResult)

      raise TypeError, "Provider must return RecordingStudioAI::Providers::BatchResult"
    end

    def build_response(batch, result, operation:, transient_items: [])
      transient_by_reference = transient_items.index_by(&:reference)
      items = if batch
                batch.batch_items.order(:position).map do |item|
                  provider_item = transient_by_reference[item.reference]
                  Contracts::BatchItemResult.new(
                    reference: item.reference, provider_item_id: item.provider_item_id, status: item.status,
                    text: provider_item&.text, structured_data: provider_item&.structured_data,
                    citations: provider_item&.citations || [], provider_native_tools: provider_item&.provider_native_tools || [],
                    finish_reason: item.finish_reason, usage: usage_from(item), cost: cost_from(item),
                    error: item_error(item), metadata: item.metadata || {}
                  )
                end
              else
                []
              end
      Contracts::BatchResponse.new(
        operation: operation, profile: batch&.profile_key&.to_sym || :medium, provider: batch&.provider,
        model: batch&.model, batch: batch, status: batch&.status || result.status, items: items,
        usage: usage_from(batch), cost: cost_from(batch), error: result.error, metadata: result.metadata
      )
    end

    def usage_from(record)
      return nil unless record && Contracts::Usage::TOKEN_FIELDS.any? { |field| !record.public_send(field).nil? }

      Contracts::Usage.new(**Contracts::Usage::TOKEN_FIELDS.to_h { |field| [field, record.public_send(field)] })
    end

    def cost_from(_record)
      nil
    end

    def item_error(item)
      return nil unless item.error_category

      Contracts::NormalizedError.new(category: item.error_category, code: item.error_code,
                                     message: item.error_message, retryable: false, provider: item.batch.provider)
    end

    def resolution_failure(request, error)
      result = error_result(error, request[:provider])
      Contracts::BatchResponse.new(operation: "batch_submit", profile: request[:profile], status: result.status,
                                   items: [], error: result.error, metadata: request[:metadata])
    end

    def error_result(error, provider)
      Providers::BatchResult.new(
        status: "failed",
        error: Contracts::NormalizedError.new(category: error.category, code: error.code, message: error.message,
                                              retryable: false, provider: provider&.to_s)
      )
    end

    def submission_failure(_error, candidate)
      Providers::BatchResult.new(
        status: "failed",
        error: Contracts::NormalizedError.new(category: "batch_submission", code: "batch_submission_failed",
                                              message: "Provider batch submission failed.", retryable: false,
                                              provider: candidate.provider.to_s)
      )
    end

    def normalize_submission_result(result, candidate)
      return result if result.success?

      Providers::BatchResult.new(
        status: "failed", provider_batch_id: result.provider_batch_id,
        error: Contracts::NormalizedError.new(
          category: "batch_submission", code: result.error.code,
          message: "Provider batch submission failed.", retryable: false,
          provider: candidate.provider.to_s, provider_code: result.error.provider_code
        ), metadata: result.metadata
      )
    end

    def identifier(value) = value.respond_to?(:id) ? value.id : nil
  end
end
