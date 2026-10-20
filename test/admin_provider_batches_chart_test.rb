# frozen_string_literal: true

require "test_helper"
require "recording_studio_ai/admin/provider_batches_chart"

class AdminProviderBatchesChartTest < Minitest::Test
  FakeRelation = Struct.new(:rows) do
    def except(*)
      self
    end

    def group(_column)
      self
    end

    def count
      rows
    end
  end

  def test_series_and_categories_follow_the_relation_counts
    relation = FakeRelation.new({ "completed" => 2, "failed" => 1 })

    assert_equal [2, 1], RecordingStudioAI::Admin::ProviderBatchesChart.series(relation).first[:data]
    assert_equal %w[completed failed], RecordingStudioAI::Admin::ProviderBatchesChart.categories(relation)
    assert_equal({ "completed" => 2, "failed" => 1 }, RecordingStudioAI::Admin::ProviderBatchesChart.status_counts(relation))
  end
end
