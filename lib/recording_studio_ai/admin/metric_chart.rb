# frozen_string_literal: true

module RecordingStudioAI
  module Admin
    # Chart window and ApexCharts options for AI Admin metric cards.
    module MetricChart
      DEFAULT_WINDOW = :last_30_days
      HIDE_X_LABELS = %w[ai_runs.failed_over_time ai_runs.stuck].freeze
      RATIO_Y_LABELS = "ai_runs.fallback_retry_rate"

      module_function

      def window_params(context)
        return {} unless context.respond_to?(:widget_time_range)

        range = context.widget_time_range(default_preset_key: DEFAULT_WINDOW)
        return {} unless range.respond_to?(:begin) && range.begin && range.end

        { interval: :day, start_at: range.begin, end_at: range.end }
      end

      def timeseries_options(identifier)
        options = {
          height: 240,
          stroke: { curve: "smooth", width: 3 },
          yaxis: { min: 0 },
          dataLabels: { enabled: false },
          grid: { xaxis: { lines: { show: false } } }
        }
        options[:xaxis] = { labels: { show: false } } if HIDE_X_LABELS.include?(identifier)
        options[:yaxis] = { min: 0, decimalsInFloat: 2 } if identifier == RATIO_Y_LABELS
        options
      end
    end
  end
end
