# frozen_string_literal: true

require_relative "metric_read"

module RecordingStudioAI
  module Admin
    # Provider batches chart and headline from the same filtered table relation.
    module ProviderBatchesChart
      module_function

      def status_counts(relation)
        scoped = relation.respond_to?(:except) ? relation.except(:order) : relation
        scoped.group(:status).count.sort.to_h
      end

      def total(relation)
        scoped = relation.respond_to?(:except) ? relation.except(:order) : relation
        scoped.count
      end

      def series(relation)
        counts = status_counts(relation)
        [{
          name: RecordingStudioAI::Copy.t("admin.screens.provider_batches.chart_title"),
          data: counts.values.map(&:to_i)
        }]
      end

      def categories(relation)
        status_counts(relation).keys.map { |status| MetricRead.group_label(status) }
      end
    end
  end
end
