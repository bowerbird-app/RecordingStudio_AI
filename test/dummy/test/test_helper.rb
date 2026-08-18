# frozen_string_literal: true

ENV["RAILS_ENV"] ||= "test"

require_relative "../config/environment"
require "rails/test_help"
require_relative "support/accessible_test_helpers"

class ActionDispatch::IntegrationTest
  include AccessibleTestHelpers
end
