# frozen_string_literal: true

require "test_helper"

class MetricsTest < Minitest::Test
  def test_metrics_register_with_operations_expose_and_staff_view
    metrics = File.read(File.expand_path("../lib/recording_studio_ai/metrics.rb", __dir__))
    engine = File.read(File.expand_path("../lib/recording_studio_ai/engine.rb", __dir__))
    gemspec = File.read(File.expand_path("../recording_studio_ai.gemspec", __dir__))
    dummy_metrics = File.read(File.expand_path("dummy/config/initializers/recording_studio_metrics.rb", __dir__))

    assert_includes metrics, "RecordingStudioMetrics.register"
    assert_includes metrics, ":ai_runs"
    assert_includes metrics, "RecordingStudioAI::Run"
    assert_includes metrics, "timeseries :over_time"
    assert_includes metrics, "field: :created_at"
    assert_includes metrics, "breakdown :by_status"
    assert_includes metrics, "field: :status"
    assert_includes metrics, "breakdown :by_model"
    assert_includes metrics, "field: :resolved_model"
    assert_includes metrics, "sum :tokens"
    assert_includes metrics, "field: :total_tokens"
    assert_includes metrics, "timeseries :tokens_over_time"
    assert_includes metrics, "average :avg_latency"
    assert_includes metrics, "field: :latency_ms"
    assert_includes metrics, "blast_radius: :site"
    assert_includes metrics, "expose: EXPOSE"
    assert_includes metrics, "api: [API]"
    assert_includes metrics, "API = :operations"
    assert_includes metrics, "Api::Access.can_view?"
    refute_includes metrics, "admin_operator?"
    refute_includes metrics, "estimated_spend"
    refute_includes metrics, "RecordingStudioMetrics::Api.register!"
    refute_includes metrics, "respond_to?"
    refute_includes metrics, "rescue"

    assert_includes metrics, "for_resource(RESOURCE).any?"
    assert_includes engine, "RecordingStudioAI::Metrics.register!"
    refute_includes engine, "RecordingStudioMetrics::Api.register!"

    assert_includes gemspec, 'spec.add_dependency "recording_studio_metrics", "~> 0.2"'
    refute_includes dummy_metrics, "RecordingStudioMetrics::Api.register!"
  end
end
