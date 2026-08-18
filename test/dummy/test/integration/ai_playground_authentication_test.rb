# frozen_string_literal: true

require "test_helper"

class AIPlaygroundAuthenticationTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  test "playground page redirects unauthenticated visitors to sign in" do
    get "/ai_playground"

    assert_redirected_to new_user_session_path
  end

  test "playground stream rejects unauthenticated requests without throwing warden" do
    post "/ai_playground/stream",
         params: { ai_playground: { prompt: "hello", profile: "medium", provider: "auto" } },
         headers: { "Accept" => "text/event-stream" }

    assert_response :unauthorized
  end

  test "authenticated visitor can open the playground" do
    user = User.create!(email: "playground-#{SecureRandom.hex(4)}@example.com", password: "password123")
    Workspace.create!(name: "Playground workspace")
    sign_in user

    get "/ai_playground"

    assert_response :success
    assert_includes response.body, "Run generate"
  end
end
