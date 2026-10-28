# frozen_string_literal: true

require "recording_studio_ai/copy"

module AdminScreens
  Copy = RecordingStudioAI::Copy unless const_defined?(:Copy, false)

  module RecordingStudioAIWidgets
    extend self

    EXPENSIVE_MODEL_MATCHER = /(gpt-5|o1|claude-opus|gemini-2\.5-pro)/i unless const_defined?(:EXPENSIVE_MODEL_MATCHER)
    WarningRow = Data.define(:text) unless const_defined?(:WarningRow)
    unless const_defined?(:ToolRow)
      ToolRow = Data.define(:key, :version, :name, :description, :cost_class, :safety, :calls_series, :success_rate,
                            :error_rate, :average_duration)
    end
    if const_defined?(:PromptRow) && PromptRow.members != %i[
      key version name owner description calls calls_series success_rate error_rate
      average_duration average_input_tokens average_output_tokens
    ]
      remove_const(:PromptRow)
    end
    unless const_defined?(:PromptRow)
      PromptRow = Data.define(:key, :version, :name, :owner, :description, :calls, :calls_series,
                              :success_rate, :error_rate, :average_duration, :average_input_tokens,
                              :average_output_tokens)
    end
    DateRangeWindow = Data.define(:start_date, :end_date, :preset_key) unless const_defined?(:DateRangeWindow)
    latency_row_members = %i[
      name calls calls_series p50_latency_ms p90_latency_ms average_latency_ms max_latency_ms
      prompt_key prompt_version resolved_model
    ]
    remove_const(:LatencyRow) if const_defined?(:LatencyRow) && LatencyRow.members != latency_row_members
    LatencyRow = Data.define(*latency_row_members) unless const_defined?(:LatencyRow)

    module AttemptErrorCodeColumn
      ERROR_CODE_KEY = :error_code

      def columns
        defined_columns = super
        return defined_columns if RecordingStudioAIWidgets.attempt_error_code_column_visible?

        defined_columns.reject { |column| column.key == ERROR_CODE_KEY }
      end

      def default_column_keys
        return super if RecordingStudioAIWidgets.attempt_error_code_column_visible?

        Array(@default_column_keys) - [ERROR_CODE_KEY]
      end
    end
    provider_row_members = %i[key class_name configured models_count calls calls_series]
    remove_const(:ProviderRow) if const_defined?(:ProviderRow) && ProviderRow.members != provider_row_members
    ProviderRow = Data.define(*provider_row_members) unless const_defined?(:ProviderRow)
    model_row_members = %i[
      provider model temperature verbosity reasoning_effort streaming structured_output batch
      tools input_modalities output_modalities calls calls_series
    ]
    remove_const(:ModelRow) if const_defined?(:ModelRow) && ModelRow.members != model_row_members
    ModelRow = Data.define(*model_row_members) unless const_defined?(:ModelRow)
    profile_row_members = %i[profile default_profile position provider model kind]
    remove_const(:ProfileRow) if const_defined?(:ProfileRow) && ProfileRow.members != profile_row_members
    ProfileRow = Data.define(*profile_row_members) unless const_defined?(:ProfileRow)

    unless const_defined?(:ATTEMPT_KIND_LABELS)
      ATTEMPT_KIND_LABELS = {
        "primary" => "1st attempt",
        "retry" => "Retry",
        "fallback" => "Fallback",
        "continuation" => "After tools"
      }.freeze
    end
    ADMIN_CONTEXT_KEY = :recording_studio_ai_admin_context unless const_defined?(:ADMIN_CONTEXT_KEY)
    WIDGET_MEMO_KEY = :recording_studio_ai_widget_memo unless const_defined?(:WIDGET_MEMO_KEY)

    def bind_admin_context!(context)
      Thread.current[ADMIN_CONTEXT_KEY] = context
      context
    end

    def clear_admin_context!
      Thread.current[ADMIN_CONTEXT_KEY] = nil
      Thread.current[WIDGET_MEMO_KEY] = nil
    end

    def admin_context
      Thread.current[ADMIN_CONTEXT_KEY]
    end

    def memoize_widget(key)
      store = (Thread.current[WIDGET_MEMO_KEY] ||= {})
      return store[key] if store.key?(key)

      store[key] = yield
    end

    # DATE(...) is portable across SQLite (gem tests) and PostgreSQL (hosts).
    def sql_calendar_date(column)
      Arel.sql("DATE(#{column})")
    end

    def normalize_sql_date(value)
      case value
      when Date then value
      when Time, DateTime, ActiveSupport::TimeWithZone then value.to_date
      else Date.parse(value.to_s)
      end
    end

    def counts_by_calendar_date(scope, column: "#{scope.klass.table_name}.created_at")
      scope.group(sql_calendar_date(column)).count.transform_keys { |key| normalize_sql_date(key) }
    end

    def sums_by_calendar_date(scope, field, column: "#{scope.klass.table_name}.created_at")
      scope.group(sql_calendar_date(column)).sum(field).transform_keys { |key| normalize_sql_date(key) }
    end

    def grouped_daily_counts(scope, *group_columns, column: "#{scope.klass.table_name}.created_at")
      scope.group(*group_columns, sql_calendar_date(column)).count.transform_keys do |key|
        *identity, date = Array(key)
        [*identity, normalize_sql_date(date)]
      end
    end

    # Fail closed: missing root yields no rows instead of every tenant's runs.
    # Binding the context lets filter option lambdas (which receive no args from
    # Recording Studio Admin) reuse the same root scope for dropdown values.
    def runs_scope(context = admin_context)
      bind_admin_context!(context) if context
      root_id = context&.root_recording&.id
      return RecordingStudioAI::Run.none if root_id.blank?

      RecordingStudioAI::Run.where(root_recording_id: root_id)
    end

    def site_admin_visible?(context)
      return false if context.blank?

      context.try(:access_recording).present? || context.try(:root_recording).present?
    end

    def site_runs_scope(context = admin_context)
      bind_admin_context!(context) if context
      return RecordingStudioAI::Run.none unless site_admin_visible?(context)

      RecordingStudioAI::Run.all
    end

    def site_tool_scope(context = admin_context)
      RecordingStudioAI::CustomToolInvocation.joins(:run).merge(site_runs_scope(context))
    end

    def tool_scope(context = admin_context)
      RecordingStudioAI::CustomToolInvocation.joins(:run).merge(runs_scope(context))
    end

    def attempts_scope(context = admin_context)
      RecordingStudioAI::Attempt.joins(:run).merge(runs_scope(context))
    end

    def batches_scope(context = admin_context)
      bind_admin_context!(context) if context
      root_id = context&.root_recording&.id
      return RecordingStudioAI::Batch.none if root_id.blank?

      RecordingStudioAI::Batch.where(root_recording_id: root_id)
    end

    def site_batches_scope(context = admin_context)
      bind_admin_context!(context) if context
      return RecordingStudioAI::Batch.none unless site_admin_visible?(context)

      RecordingStudioAI::Batch.all
    end

    def batch_distinct_values(column)
      site_batches_scope.distinct.order(column).pluck(column).compact_blank
    end

    def run_distinct_values(column)
      runs_scope.distinct.order(column).pluck(column).compact_blank
    end

    def run_present_distinct_values(column)
      runs_scope.where.not(column => nil).distinct.order(column).pluck(column).compact_blank
    end

    def site_run_distinct_values(column)
      site_runs_scope.distinct.order(column).pluck(column).compact_blank
    end

    def site_run_present_distinct_values(column)
      site_runs_scope.where.not(column => nil).distinct.order(column).pluck(column).compact_blank
    end

    def attempt_distinct_values(column)
      attempts_scope.distinct.order(column).pluck(column).compact_blank
    end

    def attempt_present_distinct_values(column)
      attempts_scope.where.not(column => [nil, ""]).distinct.order(column).pluck(column).compact_blank
    end

    def tool_distinct_values(column)
      tool_scope.distinct.order(column).pluck(column).compact_blank
    end

    def date_range_query(context, screen: AdminScreens::RecordingStudioAIRegisteredCustomToolsScreen)
      date_range = context.filter_value(:date_range) || screen.filters.find do |filter|
        filter.key == :date_range
      end.normalize(context.params)
      return { date_range_preset: :last_4_weeks } unless date_range&.start_date && date_range.end_date
      return { date_range_preset: date_range.preset_key } if date_range_matches_preset?(date_range)

      {
        start_date: date_range.start_date.iso8601,
        end_date: date_range.end_date.iso8601
      }
    end

    def date_range_matches_preset?(date_range)
      return false if date_range.preset_key.blank?
      return false unless defined?(RecordingStudioAdmin::Period)

      preset = RecordingStudioAdmin::Period.from_preset_key(date_range.preset_key)
      return false unless preset

      preset.start_date == date_range.start_date && preset.end_date == date_range.end_date
    end

    def previous_period_date_range(date_range)
      return unless date_range.respond_to?(:start_date) && date_range.respond_to?(:end_date)
      return unless date_range.start_date && date_range.end_date

      span_days = (date_range.end_date - date_range.start_date).to_i + 1
      previous_end = date_range.start_date - 1.day
      previous_start = previous_end - (span_days - 1).days
      DateRangeWindow.new(previous_start, previous_end, nil)
    end

    def number(value)
      ActionController::Base.helpers.number_with_delimiter(value.to_i)
    end

    # Numeric count: selects one/other; formatted_count is the delimited number.
    # English :one says "call"; :other says "calls" (sanctioned wording fix).
    def high_usage_alert_text(usage_today)
      Copy.t(
        "admin.alerts.high_usage",
        count: usage_today,
        formatted_count: number(usage_today)
      )
    end

    def duration(milliseconds)
      return Copy.t("common.no_data") if milliseconds.blank?

      milliseconds.to_f >= 1_000 ? format("%.1fs", milliseconds.to_f / 1_000) : "#{milliseconds.to_i}ms"
    end

    def mini_chart(series)
      render_flatpack(
        FlatPack::Chart::Component.new(
          series: [{ name: Copy.t("common.calls"), data: series }],
          type: :line,
          height: 64,
          card: false,
          class: "h-16 w-36",
          options: {
            chart: { toolbar: { show: false }, sparkline: { enabled: true } },
            colors: ["#000000"],
            stroke: { curve: "smooth", width: 2 },
            tooltip: { theme: "light" },
            xaxis: { labels: { show: false } },
            yaxis: { min: 0, labels: { show: false } },
            grid: { show: false }
          }
        )
      )
    end

    def definition_modal(modal_id:, title:, trigger_text:, aria_label:, fields:, trailing: nil)
      helpers = ActionController::Base.helpers
      body = helpers.content_tag(:div, class: "grid gap-4 text-sm") do
        labeled = fields.map do |label, value|
          helpers.content_tag(:div) do
            helpers.safe_join([
                                helpers.content_tag(:dt, label,
                                                    class: "text-sm text-[var(--surface-muted-content-color)]"),
                                helpers.content_tag(:dd, value)
                              ])
          end
        end
        helpers.safe_join([*labeled, trailing].compact)
      end
      trigger = render_flatpack(
        FlatPack::Link::Component.new(
          href: "#",
          data: { modal_id: modal_id, turbo: false },
          aria: { label: aria_label }
        )
      ) { trigger_text }
      modal = render_flatpack(
        FlatPack::Modal::Component.new(id: modal_id, title: title, size: :lg)
      ) do |component|
        component.body { body }
      end
      helpers.safe_join([trigger, modal])
    end

    def render_flatpack(component, &)
      html = component_view_context.render(component, &)
      html.respond_to?(:html_safe) ? html : html.to_s.html_safe
    end

    def component_view_context
      context = admin_context
      return context.view_context if context.respond_to?(:view_context) && context.view_context
      return context.controller.view_context if context&.controller.respond_to?(:view_context)

      fallback_component_view_context
    end

    def fallback_component_view_context
      controller = ActionController::Base.new
      request = ActionDispatch::Request.empty
      controller.set_request!(request) if controller.respond_to?(:set_request!)
      controller.view_context
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
      series_name = Copy.t("common.ai_calls") if series_name == "AI calls"
      current_week_start = Time.current.beginning_of_week
      start_week = (current_week_start - (weeks_back - 1).weeks).beginning_of_week
      range = start_week..Time.current
      daily_counts = counts_by_calendar_date(scope.where(created_at: range))

      [{
        name: series_name,
        data: week_starts(start_week, current_week_start).map do |week_start|
          {
            x: week_start.strftime("%b %-d"),
            y: sum_daily_counts_for_week(daily_counts, week_start)
          }
        end
      }]
    end

    def week_starts(start_week, current_week_start)
      starts = []
      cursor = start_week
      while cursor <= current_week_start
        starts << cursor
        cursor += 1.week
      end
      starts
    end

    def sum_daily_counts_for_week(daily_values, week_start)
      week_end = [week_start.to_date + 6, Time.current.to_date].min
      (week_start.to_date..week_end).sum { |date| daily_values.fetch(date, 0).to_i }
    end

    def warning_items(scope)
      now = Time.current
      last_day = scope.where(created_at: 24.hours.ago..now)
      previous_week = scope.where(created_at: 8.days.ago.beginning_of_day..1.day.ago.end_of_day)

      warnings = []

      usage_today = scope.where(created_at: now.beginning_of_day..now).count
      baseline_daily = counts_by_calendar_date(previous_week).values
      baseline_average = baseline_daily.empty? ? 0 : (baseline_daily.sum.to_f / baseline_daily.size)
      if usage_today >= [20, (baseline_average * 1.8).ceil].max
        warnings << {
          text: high_usage_alert_text(usage_today),
          icon: "arrow-trending-up"
        }
      end

      failed_last_day = last_day.where(status: "failed").count
      failed_previous_week = previous_week.where(status: "failed").count
      previous_failure_rate = percentage(failed_previous_week, previous_week.count)
      current_failure_rate = percentage(failed_last_day, last_day.count)
      if failed_last_day >= 3 && current_failure_rate >= [12.0, previous_failure_rate * 1.7].max
        warnings << {
          text: Copy.t("admin.alerts.error_spike", rate: current_failure_rate),
          icon: "shield-exclamation"
        }
      end

      expensive_last_day = last_day.where("resolved_model ~* ?", EXPENSIVE_MODEL_MATCHER.source).count
      expensive_share = percentage(expensive_last_day, last_day.count)
      if expensive_last_day >= 3 || expensive_share >= 35.0
        warnings << {
          text: Copy.t("admin.alerts.expensive_model", share: expensive_share),
          icon: "currency-dollar"
        }
      end

      warnings
    end

    require_relative "attempts/widget_helpers"
    require_relative "recording_studio_ai_responses/widget_helpers"
    require_relative "latency_by_model/widget_helpers"
    require_relative "ai_calls/widget_helpers"
    require_relative "registered_custom_tools/widget_helpers"
    require_relative "registered_prompts/widget_helpers"
    require_relative "registered_providers/widget_helpers"
    require_relative "registered_models/widget_helpers"
    require_relative "profiles/widget_helpers"
    require_relative "estimated_spend/widget_helpers"
  end
end
