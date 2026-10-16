# frozen_string_literal: true

require "recording_studio_metrics"

module RecordingStudioAI
  # Site-wide batch metrics, on the same operations API and access check as ai_runs.
  module BatchMetrics
    RESOURCE = :ai_batches
    BY_STATUS_DESCRIPTION = "AI batches per status (preparing, submitted, processing, completed, " \
                            "partially_completed, failed, cancelled, expired)."

    module_function

    def register!
      return if RecordingStudioMetrics.for_resource(RESOURCE).any?

      RecordingStudioMetrics.register(
        RESOURCE,
        model: RecordingStudioAI::Batch,
        blast_radius: :site,
        api_authorize: RecordingStudioAI::Metrics::AUTHORIZE
      ) do
        breakdown :by_status, title: "AI batches by status", description: BatchMetrics::BY_STATUS_DESCRIPTION,
                              unit: "count", field: :status, expose: RecordingStudioAI::Metrics::EXPOSE
      end
    end
  end
end
