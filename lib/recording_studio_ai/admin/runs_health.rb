# frozen_string_literal: true

require_relative "metric_read"

module RecordingStudioAI
  module Admin
    # Shared filtered scope for the AI run health screen: chart, table, and headline.
    module RunsHealth
      SUCCESS_CLASS = "text-[var(--color-success-background-color)]"
      DANGER_CLASS = "text-[var(--color-danger-background-color)]"
      MUTED_CLASS = "text-[var(--surface-muted-content-color)]"
      DEFAULT_RANGE = :last_4_weeks

      module_function

      def profile_token_rows(admin_context)
        filtered_runs(admin_context)
          .reorder(nil)
          .group(:profile_key)
          .sum(:total_tokens)
          .sort_by { |profile, tokens| [-tokens.to_i, profile.to_s] }
          .map do |profile, tokens|
            MetricRead::ProfileTokenRow.new(MetricRead.profile_label(profile), tokens.to_i)
          end
      end

      def chart_series(admin_context)
        runs = filtered_runs(admin_context).reorder(nil)
        bucket = group_by_bucket(admin_context)
        range = date_range_window(admin_context)
        return stuck_chart_series(runs, bucket: bucket, range: range) if stuck?(admin_context)

        failed_chart_series(runs.where(status: "failed"), bucket: bucket, range: range)
      end

      def headline_count(admin_context, previous: false)
        runs = filtered_runs(admin_context, previous: previous)
        return runs.count if stuck?(admin_context) || selected_statuses(admin_context).any?

        runs.where(status: "failed").count
      end

      def headline_change(admin_context)
        change_display(
          current: headline_count(admin_context),
          previous: headline_count(admin_context, previous: true)
        )
      end

      def change_markup(admin_context)
        change = headline_change(admin_context)
        %(<span class="#{change[:css_class]}">#{ERB::Util.html_escape(change[:text])}</span>).html_safe
      end

      def change_display(current:, previous:)
        none = RecordingStudioAI::Copy.t("common.none")
        if previous.to_i <= 0 || current.to_i == previous.to_i
          return { text: none, css_class: MUTED_CLASS }
        end

        percent = ((current.to_f - previous.to_f) / previous.to_f) * 100
        text = format("%+.1f%%", percent).sub(".0%", "%")
        css_class = percent.negative? ? SUCCESS_CLASS : DANGER_CLASS
        { text: text, css_class: css_class }
      end

      def filtered_runs(admin_context, previous: false)
        relation = AdminScreens::RecordingStudioAIWidgets.site_runs_scope(admin_context)
        range = created_at_range(admin_context, previous: previous)
        relation = relation.where(created_at: range) if range
        relation = apply_profile(relation, admin_context)
        relation = apply_status(relation, admin_context)
        relation = apply_stuck(relation, admin_context)
        relation
      end

      def health_screen_path(admin_context, extra: {})
        params = { date_range_preset: :last_30_days }.merge(extra)
        if defined?(RecordingStudioAdmin::AdminActivityLogsSupport) &&
           admin_context.respond_to?(:widget_filter_params)
          return RecordingStudioAdmin::AdminActivityLogsSupport.widget_link_path(
            admin_context,
            screen_key: "ai_runs_health",
            preset_key: :last_30_days,
            extra_params: extra
          )
        end

        "#{admin_context.admin_screen_path('ai_runs_health')}?#{params.to_query}"
      end

      def created_at_range(admin_context, previous: false)
        window = date_range_window(admin_context)
        window = AdminScreens::RecordingStudioAIWidgets.previous_period_date_range(window) if previous
        AdminScreens::RecordingStudioAIWidgets.prompt_created_at_range(window)
      end

      def date_range_window(admin_context)
        selected = admin_context.try(:filter_value, :date_range)
        return selected if selected.respond_to?(:start_date) && selected.start_date && selected.end_date

        default_date_range_window
      end

      def default_date_range_window
        if defined?(RecordingStudioAdmin::Period)
          period = RecordingStudioAdmin::Period.from_preset_key(DEFAULT_RANGE)
          if period&.start_date && period.end_date
            return AdminScreens::RecordingStudioAIWidgets::DateRangeWindow.new(
              period.start_date, period.end_date, period.preset_key
            )
          end
        end

        AdminScreens::RecordingStudioAIWidgets::DateRangeWindow.new(
          27.days.ago.to_date, Date.current, DEFAULT_RANGE
        )
      end

      def group_by_bucket(admin_context)
        value = admin_context.try(:filter_value, :group_by)
        value.present? ? value.to_sym : :day
      end

      def stuck?(admin_context)
        value = admin_context.try(:filter_value, :stuck)
        Array(value).any? { |item| item.to_s == "1" || item == true }
      end

      def selected_statuses(admin_context)
        Array(admin_context.try(:filter_value, :status)).map(&:to_s).compact_blank
      end

      def selected_profiles(admin_context)
        Array(admin_context.try(:filter_value, :profile)).map(&:to_s).compact_blank
      end

      def apply_profile(relation, admin_context)
        profiles = selected_profiles(admin_context)
        profiles.any? ? relation.where(profile_key: profiles) : relation
      end

      def apply_status(relation, admin_context)
        statuses = selected_statuses(admin_context)
        statuses.any? ? relation.where(status: statuses) : relation
      end

      def apply_stuck(relation, admin_context)
        stuck?(admin_context) ? RecordingStudioAI::Metrics::STUCK.call(relation) : relation
      end

      def stuck_chart_series(runs, bucket:, range:)
        [{
          name: RecordingStudioAI::Copy.t("admin.widgets.stuck.title"),
          data: bucketed_counts(runs, bucket: bucket, range: range)
        }]
      end

      def failed_chart_series(runs, bucket:, range:)
        buckets = AdminScreens::RecordingStudioAIWidgets.attempt_kind_bucket_keys(range, bucket)
        counts = Hash.new(0)
        runs.pluck(:error_category, :created_at).each do |category, created_at|
          next if created_at.blank?

          counts[[category.to_s, AdminScreens::RecordingStudioAIWidgets.attempt_kind_bucket_key(created_at, bucket)]] += 1
        end
        names = counts.keys.map(&:first).uniq.sort
        series = names.filter_map do |category|
          data = buckets.map do |bucket_key|
            {
              x: AdminScreens::RecordingStudioAIWidgets.attempt_kind_bucket_label(bucket_key, bucket),
              y: counts.fetch([category, bucket_key], 0)
            }
          end
          next if data.all? { |point| point[:y].zero? }

          { name: MetricRead.group_label(category), data: data }
        end
        series.presence || [{
          name: RecordingStudioAI::Copy.t("admin.screens.ai_runs_health.chart_title"),
          data: bucketed_counts(runs.none, bucket: bucket, range: range)
        }]
      end

      def bucketed_counts(runs, bucket:, range:)
        buckets = AdminScreens::RecordingStudioAIWidgets.attempt_kind_bucket_keys(range, bucket)
        counts = Hash.new(0)
        runs.pluck(:created_at).each do |created_at|
          next if created_at.blank?

          counts[AdminScreens::RecordingStudioAIWidgets.attempt_kind_bucket_key(created_at, bucket)] += 1
        end
        buckets.map do |bucket_key|
          {
            x: AdminScreens::RecordingStudioAIWidgets.attempt_kind_bucket_label(bucket_key, bucket),
            y: counts.fetch(bucket_key, 0)
          }
        end
      end
    end
  end
end
