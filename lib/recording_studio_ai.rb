# frozen_string_literal: true

require "recording_studio"
require "recording_studio_ai/version"
require "recording_studio_ai/configuration"
require "recording_studio_ai/engine"

module RecordingStudioAI
  class << self
    def configuration
      @configuration ||= Configuration.new
    end

    def configure
      yield(configuration) if block_given?
    end
  end
end
