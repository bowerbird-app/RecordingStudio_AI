# frozen_string_literal: true

module RecordingStudioAI
  module Services
    class RebuildAiCallLogSummaries
      class << self
        def call(day:)
          new(day: day).call
        end

        def lookback!(lookback_days:)
          today = Time.now.utc.to_date
          dates = []
          Integer(lookback_days).downto(1) do |days_ago|
            date = today - days_ago
            call(day: date)
            dates << date
          end
          dates
        end

        def backfill!(from:, to:)
          date = from.to_date
          finish = to.to_date
          while date <= finish
            call(day: date)
            date += 1
          end
        end
      end

      def initialize(day:)
        @day = day.to_date
      end

      def call
        LogsRegistration.register!
        connection = LogsRegistration.logging_connection
        failures = []
        [LogsRegistration.call_counts_definition, LogsRegistration.tool_calls_definition].each do |definition|
          RecordingStudioLogs::Aggregation::Runner.call(definition, day: day, connection: connection)
        rescue StandardError => e
          failures << e
        end
        raise failures.first if failures.any?

        day
      end

      private

      attr_reader :day
    end
  end
end
