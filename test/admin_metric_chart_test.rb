# frozen_string_literal: true

require "test_helper"
require "recording_studio_ai/admin/metric_chart"

class AdminMetricChartTest < Minitest::Test
  FakeRangeContext = Struct.new(:range) do
    def widget_time_range(default_preset_key: nil)
      @default_preset_key = default_preset_key
      range
    end

    attr_reader :default_preset_key
  end

  def test_failed_and_stuck_hide_x_axis_labels
    failed = RecordingStudioAI::Admin::MetricChart.timeseries_options("ai_runs.failed_over_time")
    stuck = RecordingStudioAI::Admin::MetricChart.timeseries_options("ai_runs.stuck")

    assert_equal({ show: false }, failed.dig(:xaxis, :labels))
    assert_equal({ show: false }, stuck.dig(:xaxis, :labels))
  end

  def test_retry_rate_y_axis_labels_use_two_decimal_places
    options = RecordingStudioAI::Admin::MetricChart.timeseries_options("ai_runs.fallback_retry_rate")

    assert_nil options[:xaxis]
    assert_equal 2, options.dig(:yaxis, :decimalsInFloat)
    assert_equal 0, options.dig(:yaxis, :min)
  end

  def test_window_params_default_to_last_30_days
    range = Time.utc(2026, 9, 20)..Time.utc(2026, 10, 20)
    context = FakeRangeContext.new(range)

    params = RecordingStudioAI::Admin::MetricChart.window_params(context)

    assert_equal :last_30_days, RecordingStudioAI::Admin::MetricChart::DEFAULT_WINDOW
    assert_equal :last_30_days, context.default_preset_key
    assert_equal :day, params[:interval]
    assert_equal range.begin, params[:start_at]
    assert_equal range.end, params[:end_at]
  end

  def test_window_params_omit_bounds_when_admin_has_no_period
    context = FakeRangeContext.new(nil)

    params = RecordingStudioAI::Admin::MetricChart.window_params(context)

    refute params.key?(:interval)
    refute params.key?(:start_at)
    refute params.key?(:end_at)
  end
end
