# frozen_string_literal: true

require "test_helper"
require "devise/test/integration_helpers"

class SidebarVersionTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  test "authenticated pages show the Recording Studio AI title without a vendored sidebar header" do
    user = User.create!(email: "sidebar-version-#{SecureRandom.hex(4)}@example.com", password: "Password123!")
    sign_in user

    get "/"

    assert_response :success
    assert_includes response.body, "Recording Studio AI"
    assert_select "body[data-recording-studio-default-layout='true']", count: 1
    refute_includes response.body, "v#{FlatPack::VERSION}"
    refute File.exist?(Rails.root.join("app/components/sidebar_header_component.rb"))
  end
end
