# frozen_string_literal: true

require "recording_studio_ai/agents/references"
require "recording_studio_ai/agents/request"
require "recording_studio_ai/agents/resolution"
require "recording_studio_ai/agents/runner"

module RecordingStudioAI
  # Provider-neutral hosted agent sessions. Credentials, runs, and usage stay here.
  # Session ownership belongs to the host (Recording Studio Agents).
  module Agents
    module_function

    def create_session(**kwargs)
      Runner.new.create(kwargs)
    end

    def send_input(**kwargs)
      Runner.new.send_input(kwargs)
    end

    # With a block, yields neutral stream events and returns the turn.
    # Without a block, returns an Enumerator of those events.
    def stream(**kwargs, &block)
      return Enumerator.new { |yielder| stream(**kwargs) { |event| yielder << event } } unless block

      Runner.new.stream(kwargs, &block)
    end

    def cancel(**kwargs)
      Runner.new.cancel(kwargs)
    end

    def delete_session(**kwargs)
      Runner.new.delete_session(kwargs)
    end

    def recover(**kwargs)
      Runner.new.recover(kwargs)
    end
  end
end
