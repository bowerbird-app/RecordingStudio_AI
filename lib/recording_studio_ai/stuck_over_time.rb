# frozen_string_literal: true

module RecordingStudioAI
  module StuckOverTime
    module_function

    def rows(relation, timestamp:)
      as_of = timestamp.utc
      threshold = RecordingStudioAI.configuration.stuck_run_threshold
      ((as_of.to_date - 29)..as_of.to_date).map do |day|
        point_for_day(relation, day: day, as_of: as_of, threshold: threshold)
      end
    end

    def point_for_day(relation, day:, as_of:, threshold:)
      day_end = [Time.utc(day.year, day.month, day.day) + 1.day, as_of].min
      {
        date: day.iso8601,
        value: stuck_count(relation, cutoff: day_end - threshold, day_end: day_end)
      }
    end

    def stuck_count(relation, cutoff:, day_end:)
      relation.where("#{Metrics::STUCK_SINCE_SQL} <= ?", cutoff).where(
        "(recording_studio_ai_runs.completed_at IS NOT NULL AND " \
        "recording_studio_ai_runs.completed_at > :day_end) OR " \
        "(recording_studio_ai_runs.completed_at IS NULL AND " \
        "recording_studio_ai_runs.status IN (:statuses))",
        day_end: day_end,
        statuses: Metrics::STUCK_STATUSES
      ).count
    end
  end
end
