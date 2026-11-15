# frozen_string_literal: true

ENV["RAILS_ENV"] ||= "test"

require_relative "../config/environment"
require "rails/test_help"
require_relative "support/accessible_test_helpers"

class ActiveSupport::TestCase
  include AccessibleTestHelpers
end

class ActionDispatch::IntegrationTest
  include AccessibleTestHelpers
end
