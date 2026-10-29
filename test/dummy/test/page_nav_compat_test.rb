# frozen_string_literal: true

require "test_helper"

class PageNavCompatTest < ActiveSupport::TestCase
  test "dummy does not prepend PageNav legacy onto Flatpack PageNav" do
    refute FlatPack::PageNav::Component.ancestors.map(&:name).include?("DummyFlatPackPageNavLegacy")
  end
end
