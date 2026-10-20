# frozen_string_literal: true

require "test_helper"
require "recording_studio_ai/admin/runs_health"

class AdminRunsHealthTest < Minitest::Test
  def test_change_display_colours_by_meaning_not_sign
    health = RecordingStudioAI::Admin::RunsHealth

    fewer = health.change_display(current: 2, previous: 4)
    assert_equal "-50%", fewer[:text]
    assert_equal health::SUCCESS_CLASS, fewer[:css_class]

    more = health.change_display(current: 4, previous: 2)
    assert_equal "+100%", more[:text]
    assert_equal health::DANGER_CLASS, more[:css_class]
  end

  def test_change_display_is_neutral_for_zero_and_no_prior
    health = RecordingStudioAI::Admin::RunsHealth
    none = RecordingStudioAI::Copy.t("common.none")

    zero = health.change_display(current: 3, previous: 3)
    assert_equal none, zero[:text]
    assert_equal health::MUTED_CLASS, zero[:css_class]

    no_prior = health.change_display(current: 4, previous: 0)
    assert_equal none, no_prior[:text]
    assert_equal health::MUTED_CLASS, no_prior[:css_class]

    empty = health.change_display(current: 0, previous: 0)
    assert_equal none, empty[:text]
    assert_equal health::MUTED_CLASS, empty[:css_class]
  end

  def test_failed_chart_folds_small_categories_into_other
    health = RecordingStudioAI::Admin::RunsHealth
    counts = {
      ["timeout", "2026-05-04"] => 6,
      ["rate_limit", "2026-05-04"] => 1,
      ["provider", "2026-05-04"] => 4
    }

    collapsed = health.collapsed_failed_counts(counts)

    assert_equal %w[timeout], collapsed.keys.reject { |key| key == health::OTHER_CATEGORY }
    assert_equal 6, collapsed.fetch("timeout").fetch("2026-05-04")
    assert_equal 5, collapsed.fetch(health::OTHER_CATEGORY).fetch("2026-05-04")
    assert_equal RecordingStudioAI::Copy.t("common.other"), health.failed_series_name(health::OTHER_CATEGORY)
  end
end
