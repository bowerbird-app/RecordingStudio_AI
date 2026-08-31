# frozen_string_literal: true

require "test_helper"
require "devise/test/integration_helpers"

class SidebarVersionTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  test "sidebar header shows the Recording Studio AI gem version instead of Flatpack" do
    user = User.create!(email: "sidebar-version-#{SecureRandom.hex(4)}@example.com", password: "Password123!")
    sign_in user

    get "/"

    assert_response :success
    assert_includes response.body, "Recording Studio AI"
    assert_includes response.body, "v#{RecordingStudioAI::VERSION}"
    refute_includes response.body, "v#{FlatPack::VERSION}"
    assert File.exist?(Rails.root.join("app/components/sidebar_header_component.rb"))
  end
end
