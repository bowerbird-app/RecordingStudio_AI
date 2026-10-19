# frozen_string_literal: true

require "test_helper"
require "recording_studio_ai/admin/metric_read"

class AdminMetricReadTest < Minitest::Test
  def test_grouped_timeseries_uses_groups_and_other
    result = RecordingStudioMetrics::Result.new(
      metric: "ai_runs.failed_over_time",
      type: :timeseries,
      title: "Failed AI runs",
      data: [{ date: "2026-05-04", value: 7 }],
      groups: [
        { key: "rate_limit", data: [{ date: "2026-05-04", value: 6 }] }
      ],
      other: { groups: 1, data: [{ date: "2026-05-04", value: 1 }] }
    )

    series = RecordingStudioAI::Admin::MetricRead.series_from_result(result, kind: :timeseries_groups)

    assert_equal "rate_limit", series.first[:name]
    assert_equal [{ x: "2026-05-04", y: 6.0 }], series.first[:data]
    assert_equal RecordingStudioAI::Copy.t("common.other"), series.last[:name]
    assert_equal [{ x: "2026-05-04", y: 1.0 }], series.last[:data]
  end

  def test_breakdown_series_uses_key_values
    result = RecordingStudioMetrics::Result.new(
      metric: "ai_batches.by_status",
      type: :breakdown,
      title: "AI batches by status",
      data: [{ key: "completed", value: 2 }, { key: "failed", value: 1 }]
    )

    series = RecordingStudioAI::Admin::MetricRead.series_from_result(result, kind: :breakdown)
    categories = RecordingStudioAI::Admin::MetricRead.breakdown_categories(result)

    assert_equal [2.0, 1.0], series.first[:data]
    assert_equal %w[completed failed], categories
  end

  def test_blank_breakdown_key_uses_none_label
    result = RecordingStudioMetrics::Result.new(
      metric: "ai_runs.tokens_by_profile",
      type: :breakdown,
      data: [{ key: "", value: 4 }]
    )

    assert_equal [RecordingStudioAI::Copy.t("common.none")],
                 RecordingStudioAI::Admin::MetricRead.breakdown_categories(result)
  end

  def test_window_sum_adds_every_bucket
    result = RecordingStudioMetrics::Result.new(
      metric: "ai_runs.failed_over_time",
      type: :timeseries,
      data: [{ date: "2026-05-03", value: 2 }, { date: "2026-05-04", value: 5 }]
    )
    RecordingStudioAI::Admin::MetricRead.stub(:call, result) do
      assert_equal 7.0, RecordingStudioAI::Admin::MetricRead.window_sum(
        "ai_runs.failed_over_time",
        admin_context: Object.new
      )
    end
  end

  def test_window_ratio_uses_one_year_bucket_over_the_same_window
    captured = nil
    year_result = RecordingStudioMetrics::Result.new(
      metric: "ai_runs.fallback_retry_rate",
      type: :timeseries,
      data: [{ date: "2026-01-01", value: 0.25 }]
    )
    stub = lambda do |_identifier, **params|
      captured = params
      year_result
    end

    RecordingStudioAI::Admin::MetricRead.stub(:call, stub) do
      ratio = RecordingStudioAI::Admin::MetricRead.window_ratio(
        "ai_runs.fallback_retry_rate",
        admin_context: Object.new
      )
      assert_in_delta 0.25, ratio
    end

    assert_equal :year, captured[:interval]
    assert captured[:start_at]
    assert captured[:end_at]
  end
end
