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
end
