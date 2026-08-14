# frozen_string_literal: true

module AdminScreens
  module RecordingStudioAIWidgets
    extend self

    EXPENSIVE_MODEL_MATCHER = /(gpt-5|o1|claude-opus|gemini-2\.5-pro)/i unless const_defined?(:EXPENSIVE_MODEL_MATCHER)
    WarningRow = Data.define(:text) unless const_defined?(:WarningRow)
    unless const_defined?(:ToolRow)
      ToolRow = Data.define(:key, :version, :name, :description, :cost_class, :safety, :calls_series, :success_rate,
                            :error_rate, :average_duration)
    end

    def runs_scope(context)
      scope = RecordingStudioAI::Run.all
      root_id = context.root_recording&.id
      root_id.present? ? scope.where(root_recording_id: root_id) : scope
    end

    def tool_scope(context)
      RecordingStudioAI::CustomToolInvocation.joins(:run).merge(runs_scope(context))
    end

    def attempts_scope(context)
      RecordingStudioAI::Attempt.joins(:run).merge(runs_scope(context))
    end

    def retry_rate_by_model_rows(scope, range: 30.days.ago..Time.current, limit: 3)
      runs = scope.where(created_at: range).where.not(resolved_model: nil)
      run_counts = runs.group(:resolved_model).count
      retried_run_counts = runs.where("retry_count > 0").group(:resolved_model).count

      run_counts.map do |model, count|
        [model, percentage(retried_run_counts.fetch(model, 0), count)]
      end.sort_by { |_model, rate| -rate }.first(limit)
    end

    def custom_tool_rows(context)
      now = Time.current
      invocations = tool_scope(context)
      thirty_day_invocations = invocations.where(created_at: 30.days.ago..now)
      thirty_day_counts = thirty_day_invocations.group(:tool_key, :tool_version).count
      daily_counts = thirty_day_invocations.group_by do |invocation|
        [invocation.tool_key, invocation.tool_version, invocation.created_at.to_date]
      end.transform_values(&:count)
      completed_counts = thirty_day_invocations.where(status: "completed").group(:tool_key, :tool_version).count
      error_counts = thirty_day_invocations.where(status: %w[failed denied rejected cancelled]).group(:tool_key,
                                                                                                      :tool_version).count
      average_latencies = thirty_day_invocations.group(:tool_key, :tool_version).average(:latency_ms)

      RecordingStudioAI.tools.all.map do |definition|
        key = [definition.key, definition.version]
        total = thirty_day_counts.fetch(key, 0)
        safety = definition.read_only ? "Read-only" : "Writes"
        safety = "#{safety}, destructive" if definition.destructive

        ToolRow.new(
          definition.key,
          definition.version,
          definition.name,
          definition.description,
          definition.cost,
          safety,
          (29.days.ago.to_date..Date.current).map do |date|
            { x: date.strftime("%b %-d"), y: daily_counts.fetch([*key, date], 0) }
          end,
          percentage(completed_counts.fetch(key, 0), total),
          percentage(error_counts.fetch(key, 0), total),
          duration(average_latencies[key])
        )
      end
    end

    def number(value)
      ActionController::Base.helpers.number_with_delimiter(value.to_i)
    end

    def duration(milliseconds)
      return "No data" if milliseconds.blank?

      milliseconds.to_f >= 1_000 ? format("%.1fs", milliseconds.to_f / 1_000) : "#{milliseconds.to_i}ms"
    end

    def mini_chart(series)
      options = {
        chart: { toolbar: { show: false }, sparkline: { enabled: true } },
        colors: ["#000000"],
        stroke: { curve: "smooth", width: 2 },
        tooltip: { theme: "light" },
        xaxis: { labels: { show: false } },
        yaxis: { min: 0, labels: { show: false } },
        grid: { show: false }
      }

      ActionController::Base.helpers.content_tag(
        :div,
        nil,
        class: "h-16 w-36",
        data: {
          controller: "flat-pack--chart",
          "flat-pack--chart-series-value": [{ name: "Calls", data: series }].to_json,
          "flat-pack--chart-type-value": "line",
          "flat-pack--chart-options-value": options.to_json,
          "flat-pack--chart-height-value": 64
        }
      )
    end

    def custom_tool_definition_modal(row)
      helpers = ActionController::Base.helpers
      modal_id = "custom-tool-definition-#{row.key}-#{row.version}"
      definition = RecordingStudioAI.tools.fetch(row.key, version: row.version)
      fields = {
        "Description" => definition.description,
        "Use when" => definition.use_when,
        "Do not use when" => definition.do_not_use_when,
        "Returns" => definition.returns,
        "Executor" => definition.executor_label,
        "Safety" => "#{definition.read_only ? 'Read only' : 'Writes'}; destructive: #{definition.destructive ? 'yes' : 'no'}; confirmation: #{definition.requires_confirmation ? 'required' : 'not required'}; idempotent: #{definition.idempotent ? 'yes' : 'no'}"
      }
      body = helpers.content_tag(:dl, class: "grid gap-4 text-sm md:grid-cols-2") do
        helpers.safe_join(fields.map do |label, value|
          helpers.content_tag(:div) do
            helpers.safe_join([
                                helpers.content_tag(:dt, label,
                                                    class: "text-sm text-[var(--surface-muted-content-color)]"),
                                helpers.content_tag(:dd, value)
                              ])
          end
        end)
      end
      modal = helpers.content_tag(
        :div,
        helpers.safe_join([
                            helpers.content_tag(:div, nil, class: "absolute inset-0",
                                                           data: { action: "click->flat-pack--modal#clickBackdrop" }),
                            helpers.content_tag(:div,
                                                class: "relative flex w-full min-h-screen items-start sm:items-center justify-center p-4 sm:p-6") do
                              helpers.content_tag(:div,
                                                  class: "relative flex flex-col min-h-0 max-h-[calc(100vh-2rem)] w-full overflow-hidden max-w-2xl p-4 sm:p-6 bg-[var(--modal-surface-color)] rounded-lg shadow-lg border border-[var(--modal-border-color)] transform transition-all duration-300 scale-95 opacity-0", role: "dialog", aria: { modal: true }, data: { "flat-pack--modal-target": "dialog" }) do
                                helpers.safe_join([
                                                    helpers.content_tag(:div,
                                                                        class: "flex items-center justify-between gap-4") do
                                                      helpers.safe_join([
                                                                          helpers.content_tag(:h2, "#{definition.name} v#{definition.version}",
                                                                                              class: "text-lg font-semibold text-[var(--modal-title-color)]"),
                                                                          helpers.content_tag(:button, "×", type: "button", class: "text-xl", aria: { label: "Close" },
                                                                                                            data: { action: "flat-pack--modal#close" })
                                                                        ])
                                                    end,
                                                    helpers.content_tag(:div, body, class: "mt-6")
                                                  ])
                              end
                            end
                          ]),
        id: modal_id,
        class: "fixed inset-0 z-50 hidden overflow-y-auto bg-[var(--modal-backdrop-color)] backdrop-blur-[var(--modal-backdrop-blur)] transition-opacity duration-300",
        data: { controller: "flat-pack--modal", "flat-pack--modal-close-on-backdrop-value": true,
                "flat-pack--modal-close-on-escape-value": true, action: "keydown.esc->flat-pack--modal#close" },
        aria: { hidden: true }
      )
      trigger = helpers.content_tag(:button, "#{row.name} v#{row.version}", type: "button",
                                                                            class: "text-(--color-primary-background-color) underline", data: { modal_id: modal_id }, aria: { label: "Show definition for #{row.name}" })
      helpers.safe_join([trigger, modal])
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

      [{
        name: series_name,
        data: week_starts.map do |week_start|
          {
            x: week_start.strftime("%b %-d"),
            y: calls_by_week.fetch(week_start.to_date, []).count
          }
        end
      }]
    end

    def weekly_token_series(scope, weeks_back: 12, series_name: "Token usage")
      current_week_start = Time.current.beginning_of_week
      start_week = (current_week_start - (weeks_back - 1).weeks).beginning_of_week
      tokens_by_week = scope.where(created_at: start_week..Time.current)
                            .group_by { |run| run.created_at.beginning_of_week.to_date }

      week_starts = []
      cursor = start_week
      while cursor <= current_week_start
        week_starts << cursor
        cursor += 1.week
      end

      [{
        name: series_name,
        data: week_starts.map do |week_start|
          week_runs = tokens_by_week.fetch(week_start.to_date, [])
          {
            x: week_start.strftime("%b %-d"),
            y: week_runs.sum { |run| run.total_tokens.to_i }
          }
        end
      }]
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

      warnings
    end
  end

  RecordingStudioAIAICallsWindowsWidget = RecordingStudioAdmin::Widget.new("widgets.recording_studio_ai.ai_calls_windows") do
    type :chart
    title "AI calls"
    subtitle "Weekly AI call volume for the last 4 weeks."
    description "Quick traffic trend to spot sudden growth or drop-offs."
    metadata { { period_label: "Last 30 days" } }
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
    link_to { |context| context.admin_screen_path("ai_calls") }
  end

  RecordingStudioAIToolCallsWidget = RecordingStudioAdmin::Widget.new("widgets.recording_studio_ai.tool_calls") do
    type :chart
    title "Custom Tool Calls"
    subtitle "Weekly custom tool-call volume for the last 4 weeks."
    description "Tracks how many tool calls were made each day, including today."
    metadata { { period_label: "Last 30 days" } }
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
    link_to { |context| context.admin_screen_path("tool_calls") }
  end

  RecordingStudioAIRegisteredCustomToolsWidget = RecordingStudioAdmin::Widget.new("widgets.recording_studio_ai.registered_custom_tools") do
    type :list
    title "Custom tools"
    subtitle "Most-used tools by calls in the last 30 days."
    description "Open a tool to inspect its definition and recent executions."
    list_options { { divider: true } }
    items do |context|
      rows = AdminScreens::RecordingStudioAIWidgets.tool_scope(context)
                                                   .where(created_at: 30.days.ago..Time.current)
                                                   .group(:tool_key)
                                                   .count
                                                   .sort_by { |_tool_key, count| -count }
                                                   .first(3)
      rows.map do |tool_key, calls|
        definition = RecordingStudioAI.tools.fetch(tool_key)
        next unless definition

        {
          icon: :wrench_screwdriver,
          text: definition.name,
          trailing: "#{AdminScreens::RecordingStudioAIWidgets.number(calls)} calls",
          href: "/recording_studio_ai/admin/custom_tools/#{definition.key}/versions/#{definition.version}"
        }
      end.compact.presence || [{ text: "No custom tool calls in the last 30 days." }]
    end
    link_to { |context| context.admin_screen_path("registered_custom_tools") }
  end

  RecordingStudioAIRetryRateByModelWidget = RecordingStudioAdmin::Widget.new("widgets.recording_studio_ai.retry_rate_by_model") do
    type :chart
    title "Retry rate by model"
    subtitle "Top three models by runs requiring at least one retry in the last 30 days."
    description "Highlights models with the highest share of retried runs."
    metadata { { period_label: "Last 30 days" } }
    value do |context|
      retries = AdminScreens::RecordingStudioAIWidgets.runs_scope(context)
                                                      .where(created_at: 30.days.ago..Time.current)
                                                      .sum(:retry_count)
      AdminScreens::RecordingStudioAIWidgets.number(retries)
    end
    change do |context|
      scope = AdminScreens::RecordingStudioAIWidgets.runs_scope(context)
      now = Time.current
      AdminScreens::RecordingStudioAIWidgets.percentage_change_label(
        current: scope.where(created_at: 30.days.ago..now).sum(:retry_count),
        previous: scope.where(created_at: 60.days.ago..30.days.ago).sum(:retry_count)
      )
    end
    change_good_when :down
    chart_type :bar
    series do |context|
      rows = AdminScreens::RecordingStudioAIWidgets.retry_rate_by_model_rows(
        AdminScreens::RecordingStudioAIWidgets.runs_scope(context)
      )
      [{ name: "Retry rate", data: rows.map(&:last) }]
    end
    chart_options do |context|
      rows = AdminScreens::RecordingStudioAIWidgets.retry_rate_by_model_rows(
        AdminScreens::RecordingStudioAIWidgets.runs_scope(context)
      )
      {
        height: 240,
        plotOptions: { bar: { horizontal: true, barHeight: "55%" } },
        xaxis: {
          categories: rows.map(&:first),
          labels: { show: false },
          axisBorder: { show: false },
          axisTicks: { show: false }
        },
        yaxis: { labels: { show: true } },
        dataLabels: { enabled: false },
        tooltip: { y: { formatter: "function(value) { return value + '%'; }" } },
        grid: { xaxis: { lines: { show: false } } }
      }
    end
    link_to { |context| context.admin_screen_path("attempts") }
  end

  RecordingStudioAIErrorsFailedCallsWidget = RecordingStudioAdmin::Widget.new("widgets.recording_studio_ai.errors_failed_calls") do
    type :chart
    title "Errors / failed calls"
    subtitle "Weekly failed-call volume for the last 4 weeks."
    description "Failure count trend to monitor reliability and regressions."
    metadata { { period_label: "Last 30 days" } }
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
    link_to { |context| "#{context.admin_screen_path('ai_calls')}?run_status=failed" }
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

      [{
        name: "Token usage",
        data: rows.map { |_model, total_tokens| total_tokens.to_i }
      }]
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
    link_to { |context| context.admin_screen_path("estimated_spend") }
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

      [{
        name: "Call volume",
        data: rows.map { |_model, count| count.to_i }
      }]
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
    link_to { |context| context.admin_screen_path("ai_calls") }
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

      [{
        name: "Latency (ms)",
        data: runs.map { |run| run.latency_ms.to_i }
      }]
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
    link_to { |context| "#{context.admin_screen_path('ai_calls')}?slowest=1" }
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
           values: lambda {
             RecordingStudioAI::Response.distinct.order(:response_type).pluck(:response_type).compact_blank
           },
           apply: ->(relation, value, _context) { relation.where(response_type: value) }
    filter :provider,
           options: -> { RecordingStudioAI::Response.distinct.order(:provider).pluck(:provider).compact_blank }
    filter :model,
           options: -> { RecordingStudioAI::Response.distinct.order(:model).pluck(:model).compact_blank }
    filter :finish,
           options: lambda {
             RecordingStudioAI::Response.distinct.order(:finish_reason).pluck(:finish_reason).compact_blank
           },
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

      column :created_at, title: "Created"
      column :created_at, title: "Created"
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
             value: lambda { |row, _context|
               row.attempt_id.present? ? "Attempt ##{row.attempt_id}" : "Batch item ##{row.batch_item_id}"
             }
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

  class RecordingStudioAICallsScreen < RecordingStudioAdmin::Screen
    key "ai_calls"
    icon :cpu_chip
    title "AI Calls"
    subtitle "Run-level execution history across generation, streaming, and batch operations."

    query do |context|
      AdminScreens::RecordingStudioAIWidgets.runs_scope(context).order(created_at: :desc)
    end

    filter_presentation :modal, inline_count: 3
    filter :date_range, field: :created_at, default: :last_4_weeks
    filter :group_by, values: %i[hour day week month year], default: :day
    filter :status,
           param: :run_status,
           field: :status,
           options: -> { RecordingStudioAI::Run.distinct.order(:status).pluck(:status).compact_blank },
           apply: ->(relation, value, _context) { relation.where(status: value.to_s) }
    filter :operation,
           field: :operation,
           values: -> { RecordingStudioAI::Run.distinct.order(:operation).pluck(:operation).compact_blank }
    filter :prompt,
           field: :prompt_key,
           values: -> { RecordingStudioAI::Run.where.not(prompt_key: nil).distinct.order(:prompt_key).pluck(:prompt_key) }
    filter :provider,
           values: lambda {
             RecordingStudioAI::Run.distinct.order(:resolved_provider).pluck(:resolved_provider).compact_blank
           },
           apply: ->(relation, value, _context) { relation.where(resolved_provider: value) }
    filter :custom_tool_key,
           values: lambda {
             RecordingStudioAI::CustomToolInvocation.distinct.order(:tool_key).pluck(:tool_key).compact_blank
           },
           apply: lambda { |relation, value, _context|
             relation.where(id: RecordingStudioAI::CustomToolInvocation.where(tool_key: value).select(:run_id))
           }
    filter :slowest,
           values: ["1"],
           control: :checkbox,
           apply: lambda { |relation, _value, _context|
             relation.where.not(latency_ms: nil).reorder(Arel.sql("latency_ms IS NULL ASC, latency_ms DESC"))
           }

    summary do
      change_good_when do |context|
        %w[failed cancelled].include?(context.filter_value(:status).to_s) ? :down : :up
      end
    end

    chart do
      title "AI calls trend"
      subtitle "Weekly call volume for the last 12 weeks."
      type :line
      series do |context|
        [{
          name: "AI calls",
          data: RecordingStudioAdmin::AdminActivityLogsSupport.date_series(
            context.query_result.relation.reorder(nil),
            field: :created_at,
            bucket: context.filter_value(:group_by) || :day
          )
        }]
      end
      options do
        {
          height: 300,
          stroke: { curve: "smooth", width: 3 },
          xaxis: {
            labels: { show: true },
            axisBorder: { show: false },
            axisTicks: { show: false }
          },
          yaxis: { min: 0 },
          grid: { xaxis: { lines: { show: false } } }
        }
      end
    end

    table do
      filter :search, apply: lambda { |relation, value, _context|
        if value.present?
          search = "%#{ActiveRecord::Base.sanitize_sql_like(value.to_s.strip)}%"

          relation.where(
            [
              "status ILIKE :search",
              "operation ILIKE :search",
              "profile_key ILIKE :search",
              "requested_provider ILIKE :search",
              "resolved_provider ILIKE :search",
              "resolved_model ILIKE :search",
              "prompt_namespace ILIKE :search",
              "prompt_key ILIKE :search",
              "prompt_name_snapshot ILIKE :search",
              "prompt_short_name_snapshot ILIKE :search",
              "CAST(id AS TEXT) ILIKE :search"
            ].join(" OR "),
            search: search
          )
        else
          relation
        end
      }

      column :created_at, title: "Created"
      column :operation,
             display: :badge,
             display_options: ->(_row, _context, value) { { text: value.to_s.humanize, style: :default, size: :sm } }
      column :status,
             display: :badge,
             display_options: lambda { |_row, _context, value|
               style = case value.to_s
                       when "completed" then :success
                       when "failed" then :danger
                       when "cancelled" then :warning
                       else :default
                       end
               { text: value.to_s.humanize, style: style, size: :sm }
             }
      column :profile_key, title: "Profile"
      column :prompt_short_name_snapshot, title: "Prompt"
      column :requested_provider, title: "Requested"
      column :resolved_provider, title: "Resolved"
      column :resolved_model, title: "Model"
      column :attempt_count,
             title: "Attempts",
             value: lambda { |run, context|
               count = run.attempt_count.to_i
               next count if count.zero?

               ActionController::Base.helpers.link_to(
                 count,
                 "#{context.admin_screen_path('attempts')}?run_id=#{run.id}",
                 class: "text-(--color-primary-background-color)",
                 data: { turbo_frame: "_top" }
               )
             }
      column :custom_tool_invocation_count,
             title: "Tool calls",
             value: lambda { |run, context|
               count = run.custom_tool_invocation_count.to_i
               next count if count.zero?

               ActionController::Base.helpers.link_to(
                 count,
                 "#{context.admin_screen_path('tool_calls')}?run_id=#{run.id}",
                 class: "text-(--color-primary-background-color)",
                 data: { turbo_frame: "_top" }
               )
             }
      column :total_tokens, title: "Tokens"
      column :latency_ms, title: "Latency (ms)"

      default_sort :created_at, direction: :desc
      paginate per_page: 25
    end
  end

  class RecordingStudioAIAttemptsScreen < RecordingStudioAdmin::Screen
    key "attempts"
    icon :arrow_path
    title "Attempts"
    subtitle "Provider attempts for AI calls, ordered by their execution sequence."

    query do |context|
      AdminScreens::RecordingStudioAIWidgets.attempts_scope(context).includes(:run).order(:sequence)
    end

    filter_presentation :modal, inline_count: 3
    filter :date_range, field: :created_at, default: :last_4_weeks
    filter :status,
           param: :attempt_status,
           field: :status,
           options: -> { RecordingStudioAI::Attempt.distinct.order(:status).pluck(:status).compact_blank },
           apply: ->(relation, value, _context) { relation.where(status: value.to_s) }
    filter :provider,
           field: :provider,
           values: -> { RecordingStudioAI::Attempt.distinct.order(:provider).pluck(:provider).compact_blank },
           apply: ->(relation, value, _context) { relation.where(provider: value) }
    filter :run_id,
           field: :run_id,
           apply: ->(relation, value, _context) { relation.where(run_id: value) }
    filter :kind,
           field: :kind,
           values: -> { RecordingStudioAI::Attempt.distinct.order(:kind).pluck(:kind).compact_blank },
           apply: ->(relation, value, _context) { relation.where(kind: value) }

    table do
      column :created_at, title: "Created"
      column :run_id, title: "AI call"
      column :sequence, title: "Sequence"
      column :kind,
             display: :badge,
             display_options: lambda { |_row, _context, value|
               { text: value.to_s.humanize, style: :default, size: :sm }
             }
      column :status,
             display: :badge,
             display_options: lambda { |_row, _context, value|
               style = case value.to_s
                       when "completed" then :success
                       when "failed" then :danger
                       when "cancelled" then :warning
                       else :default
                       end
               { text: value.to_s.humanize, style: style, size: :sm }
             }
      column :provider
      column :model
      column :latency_ms, title: "Latency (ms)"
      column :total_tokens, title: "Tokens"
      column :error_code, title: "Error code"

      default_sort :sequence, direction: :asc
      paginate per_page: 25
    end
  end

  class RecordingStudioAIToolCallsScreen < RecordingStudioAdmin::Screen
    key "tool_calls"
    icon :wrench_screwdriver
    title "Custom Tool Calls"
    subtitle "Custom tool invocation history with status, confirmation, and latency signals."

    query do |context|
      AdminScreens::RecordingStudioAIWidgets.tool_scope(context).includes(:run).order(created_at: :desc)
    end

    filter_presentation :modal, inline_count: 3
    filter :date_range, field: :created_at, default: :last_4_weeks
    filter :group_by, values: %i[hour day week month year], default: :day
    filter :run_id,
           field: :run_id,
           apply: ->(relation, value, _context) { relation.where(run_id: value) }
    filter :status,
           param: :tool_status,
           field: :status,
           options: -> { RecordingStudioAI::CustomToolInvocation.distinct.order(:status).pluck(:status).compact_blank },
           apply: ->(relation, value, _context) { relation.where(status: value.to_s) }
    filter :tool_key,
           field: :tool_key,
           values: -> { RecordingStudioAI::CustomToolInvocation.distinct.order(:tool_key).pluck(:tool_key).compact_blank }
    filter :confirmation,
           field: :confirmation_status,
           options: lambda {
             RecordingStudioAI::CustomToolInvocation.distinct.order(:confirmation_status).pluck(:confirmation_status).compact_blank
           },
           apply: ->(relation, value, _context) { relation.where(confirmation_status: value) }

    summary do
      change_good_when do |context|
        %w[denied failed rejected].include?(context.filter_value(:status).to_s) ? :down : :up
      end
    end

    chart do
      title "Custom tool calls trend"
      subtitle "Custom tool call volume over time."
      type :line
      series do |context|
        [{
          name: "Tool calls",
          data: RecordingStudioAdmin::AdminActivityLogsSupport.date_series(
            context.query_result.relation.reorder(nil),
            field: "recording_studio_ai_custom_tool_invocations.created_at",
            bucket: context.filter_value(:group_by) || :day
          )
        }]
      end
      options do
        {
          height: 300,
          stroke: { curve: "smooth", width: 3 },
          xaxis: {
            labels: { show: true },
            axisBorder: { show: false },
            axisTicks: { show: false }
          },
          yaxis: { min: 0 },
          grid: { xaxis: { lines: { show: false } } }
        }
      end
    end

    table do
      filter :search, apply: lambda { |relation, value, _context|
        if value.present?
          search = "%#{ActiveRecord::Base.sanitize_sql_like(value.to_s.strip)}%"

          relation.where(
            [
              "status ILIKE :search",
              "tool_key ILIKE :search",
              "tool_name_snapshot ILIKE :search",
              "provider_tool_call_id ILIKE :search",
              "error_category ILIKE :search",
              "error_code ILIKE :search",
              "error_message ILIKE :search",
              "CAST(id AS TEXT) ILIKE :search",
              "CAST(run_id AS TEXT) ILIKE :search"
            ].join(" OR "),
            search: search
          )
        else
          relation
        end
      }

      column :id, title: "Invocation"
      column :created_at, title: "Created"
      column :run_id, title: "Run"
      column :tool_key, title: "Tool"
      column :tool_version, title: "Version"
      column :status,
             display: :badge,
             display_options: lambda { |_row, _context, value|
               style = case value.to_s
                       when "completed" then :success
                       when "failed", "denied", "rejected" then :danger
                       when "cancelled" then :warning
                       else :default
                       end
               { text: value.to_s.humanize, style: style, size: :sm }
             }
      column :confirmation_status, title: "Confirmation"
      column :requires_confirmation, title: "Needs confirm"
      column :read_only, title: "Read-only"
      column :destructive, title: "Destructive"
      column :latency_ms, title: "Latency (ms)"
      column :error_code, title: "Error code"

      default_sort :created_at, direction: :desc
      paginate per_page: 25
    end
  end

  class RecordingStudioAIRegisteredCustomToolsScreen < RecordingStudioAdmin::Screen
    key "registered_custom_tools"
    icon :wrench_screwdriver
    title "Registered custom tools"
    subtitle "Definitions, safety classifications, and execution reliability across visible roots."

    query do |context|
      AdminScreens::RecordingStudioAIWidgets.custom_tool_rows(context)
    end

    table do
      title ""
      hide_columns_button
      hide_count

      column :name,
             title: "Tool",
             value: lambda { |row, _context|
               AdminScreens::RecordingStudioAIWidgets.custom_tool_definition_modal(row)
             }
      column :description, title: "Description"
      column :cost_class, title: "Cost class"
      column :safety, title: "Safety"
      column :calls_series,
             title: "Calls / 30 days",
             value: lambda { |row, _context|
               url = "/admin/screens/ai_calls?#{{ date_range_preset: :last_30_days,
                                                  custom_tool_key: row.key }.to_query}"
               ActionController::Base.helpers.link_to(
                 AdminScreens::RecordingStudioAIWidgets.mini_chart(row.calls_series),
                 url,
                 class: "inline-block",
                 data: { turbo_frame: "_top" },
                 aria: { label: "AI calls for #{row.name} in the last 30 days" }
               )
             }
      column :success_rate, title: "Success rate", value: ->(row, _context) { "#{row.success_rate}%" }
      column :error_rate, title: "Error rate", value: ->(row, _context) { "#{row.error_rate}%" }
      column :average_duration, title: "Average duration"
    end
  end

  class RecordingStudioAIEstimatedSpendScreen < RecordingStudioAdmin::Screen
    key "estimated_spend"
    icon :currency_dollar
    title "Estimated token/model spend"
    subtitle "Token usage trends and model-level consumption across AI runs."

    query do |context|
      AdminScreens::RecordingStudioAIWidgets.runs_scope(context)
                                            .where.not(total_tokens: nil)
                                            .order(created_at: :desc)
    end

    filter_presentation :modal, inline_count: 3
    filter :date_range, field: :created_at, default: :last_4_weeks
    filter :group_by, values: %i[hour day week month year], default: :day
    filter :status,
           param: :run_status,
           field: :status,
           options: -> { RecordingStudioAI::Run.distinct.order(:status).pluck(:status).compact_blank },
           apply: ->(relation, value, _context) { relation.where(status: value.to_s) }
    filter :model,
           field: :resolved_model,
           values: -> { RecordingStudioAI::Run.distinct.order(:resolved_model).pluck(:resolved_model).compact_blank },
           apply: ->(relation, value, _context) { relation.where(resolved_model: value) }
    filter :provider,
           field: :resolved_provider,
           values: lambda {
             RecordingStudioAI::Run.distinct.order(:resolved_provider).pluck(:resolved_provider).compact_blank
           },
           apply: ->(relation, value, _context) { relation.where(resolved_provider: value) }
    filter :token_min,
           param: :min_tokens,
           max: 1_000_000,
           apply: lambda { |relation, value, _context|
             value.to_i.positive? ? relation.where("total_tokens >= ?", value.to_i) : relation
           }
    filter :token_max,
           param: :max_tokens,
           max: 1_000_000,
           apply: lambda { |relation, value, _context|
             value.to_i.positive? && value.to_i < 1_000_000 ? relation.where("total_tokens <= ?", value.to_i) : relation
           }

    summary do
      change_good_when :down
    end

    chart do
      title "Estimated spend trend"
      subtitle "Token usage over time."
      type :line
      series do |context|
        [{
          name: "Total tokens",
          data: RecordingStudioAdmin::AdminActivityLogsSupport.date_series(
            context.query_result.relation.reorder(nil),
            field: :created_at,
            bucket: context.filter_value(:group_by) || :day
          ).map { |point| { x: point[:x], y: point[:y] } }
        }]
      end
      options do
        {
          height: 300,
          stroke: { curve: "smooth", width: 3 },
          xaxis: {
            labels: { show: true },
            axisBorder: { show: false },
            axisTicks: { show: false }
          },
          yaxis: { min: 0 },
          grid: { xaxis: { lines: { show: false } } }
        }
      end
    end

    table do
      column :id, title: "Run"
      column :created_at, title: "Created"
      column :status,
             display: :badge,
             display_options: lambda { |_row, _context, value|
               style = case value.to_s
                       when "completed" then :success
                       when "failed" then :danger
                       when "cancelled" then :warning
                       else :default
                       end
               { text: value.to_s.humanize, style: style, size: :sm }
             }
      column :resolved_provider, title: "Provider"
      column :resolved_model, title: "Model"
      column :total_tokens, title: "Total tokens"
      column :input_tokens, title: "Input"
      column :output_tokens, title: "Output"

      default_sort :created_at, direction: :desc
      paginate per_page: 25
    end
  end

  class RecordingStudioAISection < RecordingStudioAdmin::Section
    key "recording_studio_ai"
    icon :cpu_chip
    title "Recording Studio AI"
    subtitle "Runs, custom tools, provider batches, and retained responses"

    link :calls,
         text: "AI Calls",
         url: ->(context) { context.admin_screen_path("ai_calls") },
         style: :secondary

    link :tool_calls,
         text: "Custom Tool Calls",
         url: ->(context) { context.admin_screen_path("tool_calls") },
         style: :secondary

    link :attempts,
         text: "Attempts",
         url: ->(context) { context.admin_screen_path("attempts") },
         style: :secondary

    link :custom_tools,
         text: "Registered Tools",
         url: ->(context) { context.admin_screen_path("registered_custom_tools") },
         style: :secondary

    link :estimated_spend,
         text: "Estimated Spend",
         url: ->(context) { context.admin_screen_path("estimated_spend") },
         style: :secondary

    link :responses,
         text: "AI Responses",
         url: ->(context) { context.admin_screen_path("recording_studio_ai_responses") },
         style: :secondary

    widget "widgets.recording_studio_ai.ai_calls_windows"
    widget "widgets.recording_studio_ai.tool_calls"
    widget "widgets.recording_studio_ai.registered_custom_tools"
    widget "widgets.recording_studio_ai.retry_rate_by_model"
    widget "widgets.recording_studio_ai.errors_failed_calls"
    widget "widgets.recording_studio_ai.estimated_spend"
    widget "widgets.recording_studio_ai.calls_by_provider_model"
    widget "widgets.recording_studio_ai.slow_calls"
  end

  REGISTERABLE_WIDGETS = [
    RecordingStudioAIAICallsWindowsWidget,
    RecordingStudioAIToolCallsWidget,
    RecordingStudioAIRegisteredCustomToolsWidget,
    RecordingStudioAIRetryRateByModelWidget,
    RecordingStudioAIErrorsFailedCallsWidget,
    RecordingStudioAIEstimatedSpendWidget,
    RecordingStudioAICallsByProviderModelWidget,
    RecordingStudioAISlowCallsWidget
  ].freeze

  def self.register!
    return unless defined?(RecordingStudioAdmin)

    REGISTERABLE_WIDGETS.each { |widget| RecordingStudioAdmin.register_widget(widget) }
    RecordingStudioAdmin.register_screen(RecordingStudioAIOverviewScreen)
    RecordingStudioAdmin.register_screen(RecordingStudioAICallsScreen)
    RecordingStudioAdmin.register_screen(RecordingStudioAIAttemptsScreen)
    RecordingStudioAdmin.register_screen(RecordingStudioAIToolCallsScreen)
    RecordingStudioAdmin.register_screen(RecordingStudioAIRegisteredCustomToolsScreen)
    RecordingStudioAdmin.register_screen(RecordingStudioAIEstimatedSpendScreen)
    RecordingStudioAdmin.register_screen(RecordingStudioAIResponsesScreen)
    RecordingStudioAdmin.register_section(RecordingStudioAISection)
  end

  # Backward-compatible entry point used in earlier dummy-app workflow.
  def self.load!
    register!
  end
end
