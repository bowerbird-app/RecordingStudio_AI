# frozen_string_literal: true

module RecordingStudioAI
  module Admin
    # Reads registered AI metrics for Admin. Does not change how they are computed.
    module MetricRead
      ProfileTokenRow = Data.define(:profile, :tokens)
      StatusCountRow = Data.define(:status, :count)

      module_function

      def call(identifier, admin_context:, group_by: nil, **params)
        window = timeseries_window(admin_context, params)
        RecordingStudioMetrics.execute(
          identifier,
          context: site_context(admin_context),
          interval: window[:interval],
          start_at: window[:start_at],
          end_at: window[:end_at],
          group_by: group_by,
          cache: params.fetch(:cache, true),
          filters: RecordingStudioMetrics::Admin.execute_filters(
            identifier,
            admin_context,
            params
          )
        )
      end

      def scalar(identifier, admin_context:, **params)
        call(identifier, admin_context: admin_context, **params).value
      end

      def window_sum(identifier, admin_context:, group_by: nil, **params)
        Array(call(identifier, admin_context: admin_context, group_by: group_by, **params).data).sum do |row|
          (row[:value] || row["value"]).to_f
        end
      end

      def window_ratio(identifier, admin_context:, **params)
        window = timeseries_window(admin_context, params)
        result = call(
          identifier,
          admin_context: admin_context,
          interval: :year,
          start_at: window[:start_at],
          end_at: window[:end_at]
        )
        rows = Array(result.data)
        return 0.0 if rows.empty?

        rows.sum { |row| (row[:value] || row["value"]).to_f } / rows.size
      end

      def chart_series(identifier, admin_context:, kind:, group_by: nil, **params)
        series_from_result(
          call(identifier, admin_context: admin_context, group_by: group_by, **params),
          kind: kind
        )
      end

      def profile_token_rows(admin_context)
        Array(call("ai_runs.tokens_by_profile", admin_context: admin_context).data).map do |row|
          ProfileTokenRow.new(
            profile_label(row[:key] || row["key"]),
            (row[:value] || row["value"]).to_i
          )
        end
      end

      def series_from_result(result, kind:)
        case kind.to_sym
        when :timeseries_groups
          grouped_timeseries_series(result)
        when :breakdown
          breakdown_series(result)
        else
          timeseries_series(result)
        end
      end

      def site_context(admin_context)
        RecordingStudioMetrics::Admin.context_from_admin(
          admin_context,
          scope: :site,
          site_authorized: true
        )
      end

      def timeseries_window(admin_context, params)
        return sliced_window(params) if params[:start_at] || params[:end_at]

        range = admin_context.try(:filter_value, :date_range)
        if range.respond_to?(:start_date) && range.start_date && range.end_date
          return {
            interval: params[:interval] || :day,
            start_at: range.start_date.beginning_of_day,
            end_at: range.end_date.to_date.next_day.beginning_of_day
          }
        end

        {
          interval: params[:interval] || :day,
          start_at: 30.days.ago.beginning_of_day,
          end_at: Time.current
        }
      end

      def sliced_window(params)
        {
          interval: params[:interval],
          start_at: params[:start_at],
          end_at: params[:end_at]
        }
      end

      def timeseries_series(result)
        name = result.title.presence || result.metric
        [{ name: name, data: timeseries_points(result.data) }]
      end

      def grouped_timeseries_series(result)
        series = Array(result.groups).filter_map do |group|
          key = group[:key] || group["key"]
          data = group[:data] || group["data"]
          next if data.blank?

          { name: group_label(key), data: timeseries_points(data) }
        end
        if result.other
          other_data = result.other[:data] || result.other["data"]
          if other_data.present?
            series << { name: RecordingStudioAI::Copy.t("common.other"), data: timeseries_points(other_data) }
          end
        end
        series.presence || timeseries_series(result)
      end

      def breakdown_series(result)
        rows = Array(result.data)
        [{
          name: result.title.presence || result.metric,
          data: rows.map { |row| (row[:value] || row["value"]).to_f }
        }]
      end

      def breakdown_categories(result)
        Array(result.data).map { |row| group_label(row[:key] || row["key"]) }
      end

      def timeseries_points(rows)
        Array(rows).map do |row|
          { x: (row[:date] || row["date"]).to_s, y: (row[:value] || row["value"]).to_f }
        end
      end

      def group_label(key)
        text = key.to_s
        return RecordingStudioAI::Copy.t("common.none") if text.blank?

        text
      end

      def profile_label(key)
        group_label(key)
      end
    end
  end
end
