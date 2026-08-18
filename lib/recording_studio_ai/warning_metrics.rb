# frozen_string_literal: true

module RecordingStudioAI
  class WarningMetrics
    def initialize(since: 24.hours.ago, thresholds: RecordingStudioAI.configuration.admin_warning_thresholds,
                   root_ids: nil)
      @since = since
      @thresholds = thresholds.symbolize_keys
      @root_ids = root_ids
    end

    def call
      values = metric_values
      { since: @since, values: values, breaches: values.filter_map { |key, value| breach(key, value) } }
    end

    private

    def metric_values
      runs = scoped_runs.where(created_at: @since..)
      attempts = scoped_attempts.where(created_at: @since..)
      tools = scoped_tools.where(created_at: @since..)
      batches = scoped_batches.where(created_at: @since..)
      run_count = runs.count
      terminal_runs = runs.where(status: Run.terminal_statuses)
      terminal_attempts = attempts.where(status: Attempt.terminal_statuses)
      provider_counts = terminal_attempts.group(:provider).count
      provider_errors = terminal_attempts.where(status: "failed").group(:provider).count

      {
        runs: run_count,
        error_rate: ratio(terminal_runs.where(status: "failed").count, terminal_runs.count),
        input_tokens: complete_sum(runs, :input_tokens),
        output_tokens: complete_sum(runs, :output_tokens),
        total_tokens: complete_sum(runs, :total_tokens),
        average_latency_ms: runs.exists? ? runs.average(:latency_ms)&.to_f : nil,
        slow_calls: runs.where("latency_ms >= ?", RecordingStudioAI.configuration.admin_slow_call_threshold_ms).count,
        retries: attempts.where(kind: "retry").count,
        fallbacks: attempts.where(kind: "fallback").count,
        tool_calls: tools.count,
        maximum_tool_calls_per_run: tools.group(:run_id).count.values.max,
        expensive_model_runs: expensive_model_runs(runs),
        destructive_requests: tools.where(destructive: true).count,
        confirmation_rejections: tools.where(confirmation_status: "rejected").count,
        batch_failures: batches.where(status: %w[failed partially_completed]).count,
        batch_expirations: batches.where(status: "expired").count,
        provider_error_rate: provider_counts.keys.map do |provider|
          ratio(provider_errors.fetch(provider, 0), provider_counts.fetch(provider))
        end.compact.max
      }
    end

    def scoped_runs
      # Fail closed: nil root_ids must not mean "every tenant".
      return Run.none if @root_ids.nil?

      Run.where(root_recording_id: @root_ids)
    end

    def scoped_attempts
      return Attempt.none if @root_ids.nil?

      Attempt.joins(:run).merge(scoped_runs)
    end

    def scoped_tools
      return CustomToolInvocation.none if @root_ids.nil?

      CustomToolInvocation.joins(:run).merge(scoped_runs)
    end

    def scoped_batches
      return Batch.none if @root_ids.nil?

      Batch.where(root_recording_id: @root_ids)
    end

    def ratio(numerator, denominator) = denominator.zero? ? nil : numerator.to_f / denominator

    def complete_sum(scope, field)
      values = scope.pluck(field)
      values.empty? || values.any?(&:nil?) ? nil : values.sum
    end

    def expensive_model_runs(runs)
      models = Array(RecordingStudioAI.configuration.admin_expensive_models).map(&:to_s)
      models.empty? ? 0 : runs.where(resolved_model: models).count
    end

    def breach(key, value)
      threshold = @thresholds[key]
      { metric: key, value: value, threshold: threshold } if threshold && !value.nil? && value >= threshold
    end
  end
end
