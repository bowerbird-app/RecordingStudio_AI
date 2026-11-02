# frozen_string_literal: true

require "test_helper"

class PageNavCompatTest < ActiveSupport::TestCase
  test "dummy does not prepend PageNav legacy onto Flatpack PageNav" do
    refute FlatPack::PageNav::Component.ancestors.map(&:name).include?("DummyFlatPackPageNavLegacy")
  end

  test "dummy does not remap Button url onto Flatpack Button" do
    refute FlatPack::Button::Component.ancestors.map(&:name).include?("DummyFlatPackButtonUrl")
    refute defined?(DummyFlatPackButtonUrl)
  end

  test "dummy still maps leftover Card style and PageNav arguments" do
    assert FlatPack::Card::Component.ancestors.map(&:name).include?("DummyFlatPackCardStyle")
    assert RecordingStudio::LayoutHelper.ancestors.map(&:name).include?("DummyRecordingStudioPageNav")
  end
end
