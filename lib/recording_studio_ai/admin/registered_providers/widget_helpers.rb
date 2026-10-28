# frozen_string_literal: true

module AdminScreens
  module RecordingStudioAIWidgets
    def provider_rows(context)
      date_range = 30.days.ago.beginning_of_day..Time.current
      range_runs = runs_scope(context)
                   .where(created_at: date_range)
                   .where.not(resolved_provider: [nil, ""])
      call_counts = range_runs.group(:resolved_provider).count
      daily_counts = grouped_daily_counts(
        range_runs,
        :resolved_provider,
        column: "#{RecordingStudioAI::Run.table_name}.created_at"
      )

      rows = RecordingStudioAI.configuration.providers.map do |key, provider|
        provider_key = key.to_s
        ProviderRow.new(
          provider_key,
          provider.class.name.demodulize,
          provider.respond_to?(:configured?) ? provider.configured? : false,
          RecordingStudioAI.models.for_provider(key).length,
          call_counts.fetch(provider_key, 0),
          (date_range.begin.to_date..date_range.end.to_date).map do |date|
            { x: date.strftime("%b %-d"), y: daily_counts.fetch([provider_key, date], 0) }
          end
        )
      end
      rows.sort_by { |row| [-row.calls, row.key] }
    end

    def registered_provider_keys
      RecordingStudioAI.configuration.providers.keys.map(&:to_s)
    end

    def top_provider_call_rows(context, range: 30.days.ago..Time.current, limit: 5)
      counts = site_runs_scope(context)
               .where(created_at: range)
               .where.not(resolved_provider: [nil, ""])
               .group(:resolved_provider)
               .count

      rows = RecordingStudioAI.configuration.providers.keys.map do |key|
        [key.to_s, counts.fetch(key.to_s, 0)]
      end
      rows.sort_by { |_key, calls| -calls }.first(limit)
    end
  end
end
