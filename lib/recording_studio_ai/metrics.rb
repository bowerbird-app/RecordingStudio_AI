# frozen_string_literal: true

require_relative "api/access"
require "recording_studio_metrics"

module RecordingStudioAI
  module Metrics
    RESOURCE = :ai_runs
    API = :operations
    EXPOSE = { api: [API] }.freeze
    AUTHORIZE = ->(context) { RecordingStudioAI::Api::Access.can_view?(context) }

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
  end
end
