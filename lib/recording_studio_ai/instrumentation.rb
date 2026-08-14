# frozen_string_literal: true

require "active_support/notifications"

module RecordingStudioAI
  module Instrumentation
    SAFE_FIELDS = %i[
      id status provider model latency_ms input_tokens output_tokens total_tokens
      error_category error_code attempt_count retry_count fallback_count
      custom_tool_invocation_count item_count completed_item_count failed_item_count cancelled_item_count
      operation finish_reason citation_count
    ].freeze

    module_function

    def record(record)
      configuration = RecordingStudioAI.configuration
      return unless configuration.instrumentation_enabled

      event_names(record).each do |name|
        ActiveSupport::Notifications.instrument(
          "#{configuration.notification_namespace}.#{name}", payload(record)
        )
      end
    rescue StandardError
      nil
    end

    def record_batch_update(record)
      configuration = RecordingStudioAI.configuration
      return unless configuration.instrumentation_enabled

      ActiveSupport::Notifications.instrument("#{configuration.notification_namespace}.batch.updated", payload(record))
    rescue StandardError
      nil
    end

    def event_names(record)
      base = {
        "CustomToolInvocation" => "custom_tool",
        "BatchItem" => "batch_item"
      }.fetch(record.class.name.demodulize, record.class.name.demodulize.underscore)
      names = lifecycle_names(base, record.status)
      if base == "attempt"
        names << "retry.scheduled" if record.kind == "retry" && record.status == "running"
        names << "fallback.selected" if record.kind == "fallback" && record.status == "running"
        stream_event = lifecycle_suffix("stream", record.status)
        names << "stream.#{stream_event}" if record.streaming? && stream_event
      end
      names
    end

    def lifecycle_names(base, status)
      suffix = lifecycle_suffix(base, status)
      suffix ? ["#{base}.#{suffix}"] : []
    end

    def lifecycle_suffix(base, status)
      case base
      when "run"
        { "running" => "started", "completed" => "completed", "failed" => "failed", "cancelled" => "cancelled" }[status]
      when "attempt", "stream"
        { "running" => "started", "completed" => "completed", "failed" => "failed", "cancelled" => "failed" }[status]
      when "custom_tool"
        { "requested" => "requested", "awaiting_confirmation" => "awaiting_confirmation", "completed" => "completed",
          "denied" => "denied", "rejected" => "denied", "failed" => "failed", "cancelled" => "failed" }[status]
      when "batch"
        { "submitted" => "submitted", "processing" => "updated", "completed" => "completed",
          "partially_completed" => "completed", "failed" => "failed", "expired" => "failed",
          "cancelled" => "updated" }[status]
      when "batch_item"
        status
      end
    end

    def payload(record)
      SAFE_FIELDS.each_with_object({}) do |field, values|
        next unless record.respond_to?(field)

        value = record.public_send(field)
        next if value.nil? || (value.is_a?(String) && !safe_label?(value))

        values[field] = value
      end.tap do |values|
        values[:run_id] = record.run_id if record.respond_to?(:run_id)
        values[:batch_id] = record.batch_id if record.respond_to?(:batch_id)
        values[:attempt_id] = record.id if record.class.name.demodulize == "Attempt"
        values[:batch_item_id] = record.id if record.class.name.demodulize == "BatchItem"
        values[:tool_key] = record.tool_key if record.respond_to?(:tool_key) && safe_label?(record.tool_key)
        values[:purpose] = record.purpose if record.respond_to?(:purpose) && safe_label?(record.purpose)
      end
    end

    def safe_label?(value) = value.nil? || value.to_s.match?(/\A[a-z0-9_.:-]{1,64}\z/i)
  end

  module InstrumentedLifecycle
    extend ActiveSupport::Concern

    included do
      after_commit :instrument_recording_studio_ai_lifecycle, on: %i[create update]
    end

    private

    def instrument_recording_studio_ai_lifecycle
      if previous_changes.key?("updated_at") && !previous_changes.key?("status") && !previous_changes.key?("id")
        RecordingStudioAI::Instrumentation.record_batch_update(self) if self.class.name.demodulize == "Batch"
        return
      end

      RecordingStudioAI::Instrumentation.record(self)
    end
  end
end
