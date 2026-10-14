# frozen_string_literal: true

require_relative "api/access"
require "recording_studio_metrics"

module RecordingStudioAI
  module Metrics
    RESOURCE = :ai_runs
    API = :operations
    EXPOSE = { api: [API] }.freeze
    AUTHORIZE = ->(context) { RecordingStudioAI::Api::Access.can_view?(context) }
    STUCK_STATUSES = %w[pending running].freeze
    STUCK_SINCE_SQL = "COALESCE(recording_studio_ai_runs.started_at, recording_studio_ai_runs.created_at)"
    FAILED = ->(relation) { relation.where(status: "failed") }
    STUCK = lambda do |relation|
      cutoff = Time.current - RecordingStudioAI.configuration.stuck_run_threshold
      relation.where(status: STUCK_STATUSES).where("#{STUCK_SINCE_SQL} <= ?", cutoff)
    end
    OLDEST_STUCK_AGE = lambda do |relation, _context|
      oldest = relation.minimum(Arel.sql(STUCK_SINCE_SQL))
      oldest && (Time.current - oldest).to_i
    end
    FAILED_GROUPS = %i[error_category].freeze
    STUCK_GROUPS = %i[status operation].freeze
    FAILED_DESCRIPTION = "Runs that ended failed, by created_at (the AI Calls list date), grouped by the stored " \
                         "normalized error_category."
    STUCK_DESCRIPTION = "Pending or running runs whose started_at (or created_at if not started) is older than " \
                        "config.stuck_run_threshold (default 15 minutes)."
    OLDEST_STUCK_DESCRIPTION = "Seconds since the oldest stuck run started (or was created). Empty when none."

    module_function

    def register!
      return if RecordingStudioMetrics.for_resource(RESOURCE).any?

      RecordingStudioMetrics.register(
        RESOURCE,
        model: RecordingStudioAI::Run,
        blast_radius: :site,
        api_authorize: AUTHORIZE
      ) { RecordingStudioAI::Metrics.define_runs(self) }
    end

    def define_runs(dsl)
      define_volume(dsl)
      define_usage(dsl)
      define_health(dsl)
    end

    def define_volume(dsl)
      dsl.timeseries :over_time, title: "AI runs over time", field: :created_at, expose: EXPOSE
      dsl.breakdown :by_status, title: "AI runs by status", field: :status, expose: EXPOSE
      dsl.breakdown :by_model, title: "AI runs by model", field: :resolved_model, expose: EXPOSE
    end

    def define_usage(dsl)
      dsl.sum :tokens, title: "Tokens", field: :total_tokens, expose: EXPOSE
      dsl.timeseries :tokens_over_time,
                     title: "Tokens over time",
                     field: :created_at,
                     measurement: :sum,
                     value_field: :total_tokens,
                     expose: EXPOSE
      dsl.average :avg_latency, title: "Average latency", field: :latency_ms, expose: EXPOSE
    end

    # Filter names match the AI Calls list (operation, prompt, prompt_version, provider, model, status).
    def list_filters(status: false)
      filters = [
        RecordingStudioMetrics::Filter.new(:operation, type: :string, field: :operation),
        RecordingStudioMetrics::Filter.new(:prompt, type: :string, field: :prompt_key),
        RecordingStudioMetrics::Filter.new(:prompt_version, type: :integer, field: :prompt_version),
        RecordingStudioMetrics::Filter.new(:provider, type: :string, field: :resolved_provider),
        RecordingStudioMetrics::Filter.new(:model, type: :string, field: :resolved_model)
      ]
      return filters unless status

      filters << RecordingStudioMetrics::Filter.new(:status, type: :enum, field: :status, options: STUCK_STATUSES)
      filters
    end

    def define_health(dsl)
      dsl.timeseries :failed_over_time, title: "Failed AI runs", description: FAILED_DESCRIPTION, unit: "count",
                                        field: :created_at, scope: FAILED, group_by: FAILED_GROUPS,
                                        filters: list_filters, expose: EXPOSE
      dsl.count :stuck, title: "Stuck AI runs", description: STUCK_DESCRIPTION, unit: "count", scope: STUCK,
                        group_by: STUCK_GROUPS, filters: list_filters(status: true), cacheable: false, expose: EXPOSE
      dsl.custom :oldest_stuck_age, title: "Oldest stuck AI run age", description: OLDEST_STUCK_DESCRIPTION,
                                    result_type: :scalar, unit: "seconds", scope: STUCK, cacheable: false,
                                    filters: list_filters(status: true), expose: EXPOSE, &OLDEST_STUCK_AGE
    end
  end
end
