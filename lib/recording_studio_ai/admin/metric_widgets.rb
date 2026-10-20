# frozen_string_literal: true

require_relative "metric_read"

module AdminScreens
  module RecordingStudioAIMetricCards
    Card = Data.define(:identifier, :widget_key, :screen_key, :kind, :group_by, :widget_type)

    CARDS = [
      Card.new("ai_runs.failed_over_time", "widgets.recording_studio_ai.failed_over_time",
               "ai_runs_health", :timeseries_groups, :error_category, :chart),
      Card.new("ai_runs.stuck", "widgets.recording_studio_ai.stuck",
               "ai_runs_health", :scalar, nil, :chart),
      Card.new("ai_runs.tokens_by_profile", "widgets.recording_studio_ai.tokens_by_profile",
               "ai_runs_health", :breakdown, nil, :chart),
      Card.new("ai_runs.fallback_retry_rate", "widgets.recording_studio_ai.fallback_retry_rate",
               "ai_runs_health", :timeseries, nil, :chart),
      Card.new("ai_batches.by_status", "widgets.recording_studio_ai.batches_by_status",
               "provider_batches", :breakdown, nil, :chart)
    ].freeze

    COPY_KEYS = {
      "ai_runs.failed_over_time" => "failed_over_time",
      "ai_runs.stuck" => "stuck",
      "ai_runs.tokens_by_profile" => "tokens_by_profile",
      "ai_runs.fallback_retry_rate" => "fallback_retry_rate",
      "ai_batches.by_status" => "batches_by_status"
    }.freeze

    module_function

    def card_for(identifier)
      CARDS.find { |card| card.identifier == identifier } || raise(KeyError, identifier)
    end

    def copy_key(identifier)
      COPY_KEYS.fetch(identifier)
    end
  end

  def self.build_metric_widget(card)
    copy = RecordingStudioAIMetricCards.copy_key(card.identifier)
    RecordingStudioAdmin::Widget.new(card.widget_key) do
      type card.widget_type
      title { Copy.t("admin.widgets.#{copy}.title") }
      subtitle { Copy.t("admin.widgets.#{copy}.subtitle") }
      description { Copy.t("admin.widgets.#{copy}.description") }
      metadata { { period_label: Copy.t("common.last_30_days") } } unless card.identifier == "ai_runs.stuck"
      if %w[ai_runs.failed_over_time ai_runs.stuck ai_runs.fallback_retry_rate].include?(card.identifier)
        change_good_when :down
      end

      if card.identifier == "ai_runs.stuck"
        value do |context|
          AdminScreens::RecordingStudioAIWidgets.number(
            RecordingStudioAI::Admin::MetricRead.scalar("ai_runs.stuck", admin_context: context).to_i
          )
        end
        chart_type :line
        series do |context|
          RecordingStudioAI::Admin::MetricRead.chart_series(
            "ai_runs.stuck_over_time",
            admin_context: context,
            kind: :timeseries
          )
        end
        chart_options do
          {
            height: 240,
            stroke: { curve: "smooth", width: 3 },
            yaxis: { min: 0 },
            dataLabels: { enabled: false },
            grid: { xaxis: { lines: { show: false } } }
          }
        end
      else
        value do |context|
          AdminScreens.metric_widget_value(card, context)
        end
        chart_type(card.kind == :breakdown ? :bar : :line)
        series do |context|
          RecordingStudioAI::Admin::MetricRead.chart_series(
            card.identifier,
            admin_context: context,
            kind: card.kind,
            group_by: card.group_by
          )
        end
        chart_options do |context|
          AdminScreens.metric_chart_options(card, context)
        end
      end

      link_to { |context| AdminScreens.metric_widget_path(card, context) }
    end
  end

  def self.metric_widget_path(card, context)
    extra = case card.identifier
            when "ai_runs.failed_over_time" then { run_status: "failed" }
            when "ai_runs.stuck" then { stuck: "1" }
            end
    return context.admin_screen_path(card.screen_key) if extra.nil?

    RecordingStudioAI::Admin::RunsHealth.health_screen_path(context, extra: extra)
  end

  def self.metric_widget_value(card, context)
    if card.identifier == "ai_runs.fallback_retry_rate"
      return format(
        "%.0f%%",
        RecordingStudioAI::Admin::MetricRead.window_ratio(card.identifier, admin_context: context) * 100
      )
    end

    AdminScreens::RecordingStudioAIWidgets.number(
      RecordingStudioAI::Admin::MetricRead.window_sum(
        card.identifier,
        admin_context: context,
        group_by: card.group_by
      ).to_i
    )
  end

  def self.metric_chart_options(card, context)
    base = {
      height: 240,
      dataLabels: { enabled: false },
      grid: { xaxis: { lines: { show: false } } }
    }
    return base.merge(stroke: { curve: "smooth", width: 3 }, yaxis: { min: 0 }) unless card.kind == :breakdown

    result = RecordingStudioAI::Admin::MetricRead.call(card.identifier, admin_context: context)
    categories = RecordingStudioAI::Admin::MetricRead.breakdown_categories(result)
    base.merge(
      plotOptions: { bar: { horizontal: true, barHeight: "55%" } },
      xaxis: { categories: categories, labels: { show: false }, axisBorder: { show: false }, axisTicks: { show: false } },
      yaxis: { labels: { show: true } }
    )
  end

  RecordingStudioAIFailedOverTimeWidget = build_metric_widget(RecordingStudioAIMetricCards.card_for("ai_runs.failed_over_time"))
  RecordingStudioAIStuckWidget = build_metric_widget(RecordingStudioAIMetricCards.card_for("ai_runs.stuck"))
  RecordingStudioAITokensByProfileWidget = build_metric_widget(RecordingStudioAIMetricCards.card_for("ai_runs.tokens_by_profile"))
  RecordingStudioAIFallbackRetryRateWidget = build_metric_widget(RecordingStudioAIMetricCards.card_for("ai_runs.fallback_retry_rate"))
  RecordingStudioAIBatchesByStatusWidget = build_metric_widget(RecordingStudioAIMetricCards.card_for("ai_batches.by_status"))
end
