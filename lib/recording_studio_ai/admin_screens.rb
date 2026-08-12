# frozen_string_literal: true

module AdminScreens
  module RecordingStudioAIWidgets
    extend self

    EXPENSIVE_MODEL_MATCHER = /(gpt-5|o1|claude-opus|gemini-2\.5-pro)/i unless const_defined?(:EXPENSIVE_MODEL_MATCHER)

    def runs_scope(context)
      scope = RecordingStudioAI::Run.all
      root_id = context.root_recording&.id
      root_id.present? ? scope.where(root_recording_id: root_id) : scope
    end

    def tool_scope(context)
      RecordingStudioAI::CustomToolInvocation.joins(:run).merge(runs_scope(context))
    end

    def number(value)
      ActionController::Base.helpers.number_with_delimiter(value.to_i)
    end

    def percentage(part, whole)
      return 0.0 if whole.to_i <= 0

      ((part.to_f / whole.to_f) * 100).round(1)
    end

    def percentage_change_label(current:, previous:)
      change =
        if previous.to_i <= 0
          current.to_i.positive? ? 100.0 : 0.0
        else
          (((current.to_f - previous.to_f) / previous.to_f) * 100).round(1)
        end

      formatted = (change % 1).zero? ? change.to_i.to_s : format("%.1f", change)
      sign = change.positive? ? "+" : ""
      "#{sign}#{formatted}%"
    end

    def this_week_range(reference_time: Time.current)
      reference_time.beginning_of_week..reference_time
    end

    def previous_week_range(reference_time: Time.current)
      current_week_start = reference_time.beginning_of_week
      (current_week_start - 1.week)..(current_week_start - 1.second)
    end

    def trailing_weeks_range(weeks_back:, reference_time: Time.current)
      current_week_start = reference_time.beginning_of_week
      start_week = (current_week_start - (weeks_back - 1).weeks).beginning_of_week
      start_week..reference_time
    end

    def weekly_calls_series(scope, weeks_back: 12, series_name: "AI calls")
      current_week_start = Time.current.beginning_of_week
      start_week = (current_week_start - (weeks_back - 1).weeks).beginning_of_week
      calls_by_week = scope.where(created_at: start_week..Time.current)
        .group_by { |run| run.created_at.beginning_of_week.to_date }

      week_starts = []
      cursor = start_week
      while cursor <= current_week_start
        week_starts << cursor
        cursor += 1.week
      end

      [ {
        name: series_name,
        data: week_starts.map do |week_start|
          {
            x: week_start.strftime("%b %-d"),
            y: calls_by_week.fetch(week_start.to_date, []).count
          }
        end
      } ]
    end

    def top_model_token_rows(scope, range:, limit: 5)
      scope.where(created_at: range)
        .where.not(total_tokens: nil)
        .group(:resolved_model)
        .sum(:total_tokens)
        .sort_by { |_model, total_tokens| -total_tokens.to_i }
        .first(limit)
    end

    def token_change_label(scope, current_range:, previous_range:)
      current = scope.where(created_at: current_range).where.not(total_tokens: nil).sum(:total_tokens)
      previous = scope.where(created_at: previous_range).where.not(total_tokens: nil).sum(:total_tokens)
      percentage_change_label(current: current, previous: previous)
    end

    def warning_items(scope)
      now = Time.current
      last_day = scope.where(created_at: 24.hours.ago..now)
      previous_week = scope.where(created_at: 8.days.ago.beginning_of_day..1.day.ago.end_of_day)

      warnings = []

      usage_today = scope.where(created_at: now.beginning_of_day..now).count
      baseline_daily = previous_week.group_by { |run| run.created_at.to_date }.values.map(&:count)
      baseline_average = baseline_daily.empty? ? 0 : (baseline_daily.sum.to_f / baseline_daily.size)
      if usage_today >= [20, (baseline_average * 1.8).ceil].max
        warnings << {
          text: "Unusually high usage today: #{number(usage_today)} calls",
          icon: "arrow-trending-up"
        }
      end

      failed_last_day = last_day.where(status: "failed").count
      failed_previous_week = previous_week.where(status: "failed").count
      previous_failure_rate = percentage(failed_previous_week, previous_week.count)
      current_failure_rate = percentage(failed_last_day, last_day.count)
      if failed_last_day >= 3 && current_failure_rate >= [12.0, previous_failure_rate * 1.7].max
        warnings << {
          text: "Error spike: #{current_failure_rate}% failures in the last 24h",
          icon: "shield-exclamation"
        }
      end

      expensive_last_day = last_day.where("resolved_model ~* ?", EXPENSIVE_MODEL_MATCHER.source).count
      expensive_share = percentage(expensive_last_day, last_day.count)
      if expensive_last_day >= 3 || expensive_share >= 35.0
        warnings << {
          text: "Expensive model usage elevated: #{expensive_share}% in the last 24h",
          icon: "currency-dollar"
        }
      end

      warnings.presence || [ { text: "No warning thresholds triggered in the last 24h.", icon: "check-circle" } ]
    end
  end

  RecordingStudioAIAICallsWindowsWidget = RecordingStudioAdmin::Widget.new("widgets.recording_studio_ai.ai_calls_windows") do
    type :chart
    title "AI calls"
    subtitle "Weekly AI call volume for the last 4 weeks."
    description "Quick traffic trend to spot sudden growth or drop-offs."
    metadata { { period_label: "This week" } }
    value do |context|
      runs = AdminScreens::RecordingStudioAIWidgets.runs_scope(context)
      AdminScreens::RecordingStudioAIWidgets.number(
        runs.where(created_at: AdminScreens::RecordingStudioAIWidgets.trailing_weeks_range(weeks_back: 4)).count
      )
    end
    change do |context|
      runs = AdminScreens::RecordingStudioAIWidgets.runs_scope(context)
      current = runs.where(created_at: AdminScreens::RecordingStudioAIWidgets.this_week_range).count
      previous = runs.where(created_at: AdminScreens::RecordingStudioAIWidgets.previous_week_range).count
      AdminScreens::RecordingStudioAIWidgets.percentage_change_label(current: current, previous: previous)
    end
    change_good_when :up
    chart_type :line
    series do |context|
      AdminScreens::RecordingStudioAIWidgets.weekly_calls_series(
        AdminScreens::RecordingStudioAIWidgets.runs_scope(context),
        weeks_back: 4,
        series_name: "AI calls"
      )
    end
    chart_options do
      {
        height: 240,
        stroke: { curve: "smooth", width: 3 },
        xaxis: {
          labels: { show: false },
          axisBorder: { show: false },
          axisTicks: { show: false }
        },
        grid: { xaxis: { lines: { show: false } } },
        yaxis: { min: 0, labels: { show: false } }
      }
    end
    link_to { |context| context.admin_screen_path("recording_studio_ai_overview") }
  end

  RecordingStudioAIToolCallsWidget = RecordingStudioAdmin::Widget.new("widgets.recording_studio_ai.tool_calls") do
    type :chart
    title "Tool calls"
    subtitle "Weekly custom tool-call volume for the last 4 weeks."
    description "Tracks how many tool calls were made each day, including today."
    metadata { { period_label: "This week" } }
    value do |context|
      count = AdminScreens::RecordingStudioAIWidgets.tool_scope(context)
        .where(created_at: AdminScreens::RecordingStudioAIWidgets.trailing_weeks_range(weeks_back: 4))
        .count
      AdminScreens::RecordingStudioAIWidgets.number(count)
    end
    change do |context|
      scope = AdminScreens::RecordingStudioAIWidgets.tool_scope(context)
      current = scope.where(created_at: AdminScreens::RecordingStudioAIWidgets.this_week_range).count
      previous = scope.where(created_at: AdminScreens::RecordingStudioAIWidgets.previous_week_range).count
      AdminScreens::RecordingStudioAIWidgets.percentage_change_label(current: current, previous: previous)
    end
    change_good_when :up
    chart_type :line
    series do |context|
      AdminScreens::RecordingStudioAIWidgets.weekly_calls_series(
        AdminScreens::RecordingStudioAIWidgets.tool_scope(context),
        weeks_back: 4,
        series_name: "Tool calls"
      )
    end
    chart_options do
      {
        height: 240,
        stroke: { curve: "smooth", width: 3 },
        xaxis: {
          labels: { show: false },
          axisBorder: { show: false },
          axisTicks: { show: false }
        },
        grid: { xaxis: { lines: { show: false } } },
        yaxis: { min: 0, labels: { show: false } }
      }
    end
    link_to { |context| context.admin_screen_path("recording_studio_ai_overview") }
  end

  RecordingStudioAIErrorsFailedCallsWidget = RecordingStudioAdmin::Widget.new("widgets.recording_studio_ai.errors_failed_calls") do
    type :chart
    title "Errors / failed calls"
    subtitle "Weekly failed-call volume for the last 4 weeks."
    description "Failure count trend to monitor reliability and regressions."
    metadata { { period_label: "This week" } }
    value do |context|
      failed_runs = AdminScreens::RecordingStudioAIWidgets.runs_scope(context).where(status: "failed")
      AdminScreens::RecordingStudioAIWidgets.number(
        failed_runs.where(created_at: AdminScreens::RecordingStudioAIWidgets.trailing_weeks_range(weeks_back: 4)).count
      )
    end
    change do |context|
      failed_runs = AdminScreens::RecordingStudioAIWidgets.runs_scope(context).where(status: "failed")
      current = failed_runs.where(created_at: AdminScreens::RecordingStudioAIWidgets.this_week_range).count
      previous = failed_runs.where(created_at: AdminScreens::RecordingStudioAIWidgets.previous_week_range).count
      AdminScreens::RecordingStudioAIWidgets.percentage_change_label(current: current, previous: previous)
    end
    change_good_when :down
    chart_type :line
    series do |context|
      failed_runs = AdminScreens::RecordingStudioAIWidgets.runs_scope(context).where(status: "failed")
      AdminScreens::RecordingStudioAIWidgets.weekly_calls_series(
        failed_runs,
        weeks_back: 4,
        series_name: "Failed calls"
      )
    end
    chart_options do
      {
        height: 240,
        stroke: { curve: "smooth", width: 3 },
        xaxis: {
          labels: { show: false },
          axisBorder: { show: false },
          axisTicks: { show: false }
        },
        grid: { xaxis: { lines: { show: false } } },
        yaxis: { min: 0, labels: { show: false } }
      }
    end
    link_to { |context| context.admin_screen_path("recording_studio_ai_overview") }
  end

  RecordingStudioAIEstimatedSpendWidget = RecordingStudioAdmin::Widget.new("widgets.recording_studio_ai.estimated_spend") do
    type :chart
    title "Estimated token/model spend"
    subtitle "Top 5 models by token usage in the last 30 days."
    description "Ranks models by token usage so spend concentration is immediately visible."
    metadata { { period_label: "Last 30 days" } }
    value do |context|
      runs = AdminScreens::RecordingStudioAIWidgets.runs_scope(context)
      total_tokens = runs.where(created_at: 30.days.ago..Time.current).where.not(total_tokens: nil).sum(:total_tokens)
      AdminScreens::RecordingStudioAIWidgets.number(total_tokens)
    end
    change do |context|
      now = Time.current
      AdminScreens::RecordingStudioAIWidgets.token_change_label(
        AdminScreens::RecordingStudioAIWidgets.runs_scope(context),
        current_range: 30.days.ago..now,
        previous_range: 60.days.ago..30.days.ago
      )
    end
    change_good_when :down
    chart_type :bar
    series do |context|
      rows = AdminScreens::RecordingStudioAIWidgets.top_model_token_rows(
        AdminScreens::RecordingStudioAIWidgets.runs_scope(context),
        range: 30.days.ago..Time.current,
        limit: 5
      )

      [ {
        name: "Token usage",
        data: rows.map { |_model, total_tokens| total_tokens.to_i }
      } ]
    end
    chart_options do |context|
      rows = AdminScreens::RecordingStudioAIWidgets.top_model_token_rows(
        AdminScreens::RecordingStudioAIWidgets.runs_scope(context),
        range: 30.days.ago..Time.current,
        limit: 5
      )

      {
        height: 240,
        plotOptions: {
          bar: {
            horizontal: true,
            barHeight: "55%"
          }
        },
        xaxis: {
          categories: rows.map { |model, _total_tokens| model.presence || "Unknown" },
          labels: { show: false },
          axisBorder: { show: false },
          axisTicks: { show: false }
        },
        yaxis: {
          labels: { show: true }
        },
        dataLabels: { enabled: false },
        grid: { xaxis: { lines: { show: false } } }
      }
    end
    link_to { |context| context.admin_screen_path("recording_studio_ai_overview") }
  end

  RecordingStudioAICallsByProviderModelWidget = RecordingStudioAdmin::Widget.new("widgets.recording_studio_ai.calls_by_provider_model") do
    type :chart
    title "Calls by provider/model"
    subtitle "Top 5 models by call volume in the last 30 days."
    description "Ranks models by call count so usage concentration is easy to compare."
    metadata { { period_label: "Last 30 days" } }
    value do |context|
      runs = AdminScreens::RecordingStudioAIWidgets.runs_scope(context).where(created_at: 30.days.ago..Time.current)
      AdminScreens::RecordingStudioAIWidgets.number(runs.count)
    end
    change do |context|
      runs = AdminScreens::RecordingStudioAIWidgets.runs_scope(context)
      current = runs.where(created_at: 30.days.ago..Time.current).count
      previous = runs.where(created_at: 60.days.ago..30.days.ago).count
      AdminScreens::RecordingStudioAIWidgets.percentage_change_label(current: current, previous: previous)
    end
    change_good_when :up
    chart_type :bar
    series do |context|
      rows = AdminScreens::RecordingStudioAIWidgets.runs_scope(context)
        .where(created_at: 30.days.ago..Time.current)
        .group(:resolved_model)
        .count
        .sort_by { |_model, count| -count.to_i }
        .first(5)

      [ {
        name: "Call volume",
        data: rows.map { |_model, count| count.to_i }
      } ]
    end
    chart_options do |context|
      rows = AdminScreens::RecordingStudioAIWidgets.runs_scope(context)
        .where(created_at: 30.days.ago..Time.current)
        .group(:resolved_model)
        .count
        .sort_by { |_model, count| -count.to_i }
        .first(5)

      {
        height: 240,
        plotOptions: {
          bar: {
            horizontal: true,
            barHeight: "55%"
          }
        },
        xaxis: {
          categories: rows.map { |model, _count| model.presence || "Unknown" },
          labels: { show: false },
          axisBorder: { show: false },
          axisTicks: { show: false }
        },
        yaxis: {
          labels: { show: true }
        },
        dataLabels: { enabled: false },
        grid: { xaxis: { lines: { show: false } } }
      }
    end
    link_to { |context| context.admin_screen_path("recording_studio_ai_overview") }
  end

  RecordingStudioAISlowCallsWidget = RecordingStudioAdmin::Widget.new("widgets.recording_studio_ai.slow_calls") do
    type :chart
    title "Slow calls"
    subtitle "Top 5 slowest calls in the last 30 days."
    description "Highlights the slowest calls by model so latency hot spots are easy to scan."
    metadata { { period_label: "Last 30 days" } }
    value do |context|
      runs = AdminScreens::RecordingStudioAIWidgets.runs_scope(context)
        .where(created_at: 30.days.ago..Time.current)
        .where.not(latency_ms: nil)
      max_latency = runs.maximum(:latency_ms).to_i
      "#{AdminScreens::RecordingStudioAIWidgets.number(max_latency)} ms"
    end
    change do |context|
      runs = AdminScreens::RecordingStudioAIWidgets.runs_scope(context).where.not(latency_ms: nil)
      current_avg = runs.where(created_at: 30.days.ago..Time.current).average(:latency_ms).to_f
      previous_avg = runs.where(created_at: 60.days.ago..30.days.ago).average(:latency_ms).to_f
      AdminScreens::RecordingStudioAIWidgets.percentage_change_label(current: current_avg, previous: previous_avg)
    end
    change_good_when :down
    chart_type :bar
    series do |context|
      runs = AdminScreens::RecordingStudioAIWidgets.runs_scope(context)
        .where(created_at: 30.days.ago..Time.current)
        .where.not(latency_ms: nil)
        .order(latency_ms: :desc)
        .limit(5)

      [ {
        name: "Latency (ms)",
        data: runs.map { |run| run.latency_ms.to_i }
      } ]
    end
    chart_options do |context|
      runs = AdminScreens::RecordingStudioAIWidgets.runs_scope(context)
        .where(created_at: 30.days.ago..Time.current)
        .where.not(latency_ms: nil)
        .order(latency_ms: :desc)
        .limit(5)

      {
        height: 240,
        plotOptions: {
          bar: {
            horizontal: true,
            barHeight: "55%"
          }
        },
        xaxis: {
          categories: runs.map { |run| run.resolved_model.presence || "Unknown" },
          labels: { show: false },
          axisBorder: { show: false },
          axisTicks: { show: false }
        },
        yaxis: {
          labels: { show: true }
        },
        dataLabels: { enabled: false },
        grid: { xaxis: { lines: { show: false } } }
      }
    end
    link_to { |context| context.admin_screen_path("recording_studio_ai_overview") }
  end

  RecordingStudioAIWarningsWidget = RecordingStudioAdmin::Widget.new("widgets.recording_studio_ai.warnings") do
    type :list
    title "Warnings"
    subtitle "Obvious usage, reliability, and spend signals."
    description "Deterministic checks for high usage, error spikes, and expensive model concentration."
    list_options { { divider: true } }
    items do |context|
      AdminScreens::RecordingStudioAIWidgets.warning_items(
        AdminScreens::RecordingStudioAIWidgets.runs_scope(context)
      )
    end
    link_to do |context|
      context.admin_screen_path("recording_studio_ai_overview")
    end
  end

  class RecordingStudioAIOverviewScreen < RecordingStudioAdmin::Screen
    key "recording_studio_ai_overview"
    icon :cpu_chip
    title "Recording Studio AI"
    subtitle "Entry point for AI administration views."

    query do |_context|
      RecordingStudioAI::Run.order(created_at: :desc)
    end
  end

  class RecordingStudioAIResponsesScreen < RecordingStudioAdmin::Screen
    key "recording_studio_ai_responses"
    icon :table
    title "AI Responses"
    subtitle "Persisted response records from Recording Studio AI executions."

    query do |_context|
      RecordingStudioAI::Response.includes(attempt: :run, batch_item: :run).order(created_at: :desc)
    end

    filter_presentation :modal, inline_count: 3
    filter :date_range, field: :created_at, default: :last_30_days
    filter :type,
           values: -> { RecordingStudioAI::Response.distinct.order(:response_type).pluck(:response_type).compact_blank },
           apply: ->(relation, value, _context) { relation.where(response_type: value) }
    filter :provider,
           options: -> { RecordingStudioAI::Response.distinct.order(:provider).pluck(:provider).compact_blank }
    filter :model,
           options: -> { RecordingStudioAI::Response.distinct.order(:model).pluck(:model).compact_blank }
    filter :finish,
           options: -> { RecordingStudioAI::Response.distinct.order(:finish_reason).pluck(:finish_reason).compact_blank },
           apply: ->(relation, value, _context) { relation.where(finish_reason: value) }
    filter :complete,
           values: ["1"],
           control: :checkbox,
           apply: ->(relation, _value, _context) { relation.where(complete: true) }

    table do
      filter :search, apply: lambda { |relation, value, _context|
        if value.present?
          search = "%#{ActiveRecord::Base.sanitize_sql_like(value.to_s.strip)}%"

          relation.where(
            [
              "provider ILIKE :search",
              "model ILIKE :search",
              "response_type ILIKE :search",
              "provider_response_id ILIKE :search",
              "finish_reason ILIKE :search",
              "CAST(attempt_id AS TEXT) ILIKE :search",
              "CAST(batch_item_id AS TEXT) ILIKE :search"
            ].join(" OR "),
            search: search
          )
        else
          relation
        end
      }

      column :response,
             title: "Response",
             sortable: false,
             value: lambda { |row, _context|
               ActionController::Base.helpers.link_to(
                 "Response ##{row.id}",
                 "/recording_studio_ai/admin/retained_responses/#{row.id}",
                 class: "text-(--color-primary-background-color) underline",
                 data: { turbo_frame: "_top" }
               )
             }
      column :created_at, title: "Created"
      column :response_type,
             title: "Type",
             display: :badge,
             display_options: lambda { |_row, _context, value|
               style = value.to_s == "error" ? :danger : :default
               { text: value.to_s.humanize, style: style, size: :sm }
             }
      column :source,
             sortable: false,
             value: ->(row, _context) { row.attempt_id.present? ? "Attempt ##{row.attempt_id}" : "Batch item ##{row.batch_item_id}" }
      column :run_id,
             title: "Run",
             sortable: false,
             value: ->(row, _context) { row.attempt&.run_id || row.batch_item&.run_id }
      column :provider
      column :model
      column :finish_reason, title: "Finish", sortable: false
      column :completion,
             title: "Complete",
             sortable: false,
             value: lambda { |row, _context|
               if row.complete.nil?
                 "Unknown"
               elsif row.complete
                 "Yes"
               else
                 "No"
               end
             },
             display: :badge,
             display_options: lambda { |_row, _context, value|
               style = case value
                       when "Yes" then :success
                       when "No" then :warning
                       else :default
                       end
               { text: value, style: style, size: :sm }
             }
      column :byte_size, title: "Bytes"
      column :expires_at, title: "Expires"

      default_sort :created_at, direction: :desc
      paginate per_page: 25
    end
  end

  class RecordingStudioAISection < RecordingStudioAdmin::Section
    key "recording_studio_ai"
    icon :cpu_chip
    title "Recording Studio AI"
    subtitle "Runs, custom tools, provider batches, and retained responses"

    link :responses,
         text: "AI Responses",
         url: ->(context) { context.admin_screen_path("recording_studio_ai_responses") },
         style: :secondary

    widget "widgets.recording_studio_ai.ai_calls_windows"
    widget "widgets.recording_studio_ai.tool_calls"
    widget "widgets.recording_studio_ai.errors_failed_calls"
    widget "widgets.recording_studio_ai.estimated_spend"
    widget "widgets.recording_studio_ai.calls_by_provider_model"
    widget "widgets.recording_studio_ai.slow_calls"
    widget "widgets.recording_studio_ai.warnings"
  end

  REGISTERABLE_WIDGETS = [
    RecordingStudioAIAICallsWindowsWidget,
    RecordingStudioAIToolCallsWidget,
    RecordingStudioAIErrorsFailedCallsWidget,
    RecordingStudioAIEstimatedSpendWidget,
    RecordingStudioAICallsByProviderModelWidget,
    RecordingStudioAISlowCallsWidget,
    RecordingStudioAIWarningsWidget
  ].freeze

  def self.register!
    return unless defined?(RecordingStudioAdmin)

    REGISTERABLE_WIDGETS.each { |widget| RecordingStudioAdmin.register_widget(widget) }
    RecordingStudioAdmin.register_screen(RecordingStudioAIOverviewScreen)
    RecordingStudioAdmin.register_screen(RecordingStudioAIResponsesScreen)
    RecordingStudioAdmin.register_section(RecordingStudioAISection)
  end

  # Backward-compatible entry point used in earlier dummy-app workflow.
  def self.load!
    register!
  end
end
