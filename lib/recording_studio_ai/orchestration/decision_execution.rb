# frozen_string_literal: true

module RecordingStudioAI
  module Orchestration
    # The execution spine reads one Hash. A decision supplies the typed state and
    # questions plus empty generation channels so RunPersistence,
    # AttemptPersistence, and PlanExecutor keep their existing readers. This Hash
    # is internal: it is neither a public contract nor a prompt.
    module DecisionExecution
      EMPTY_GENERATION_CHANNELS = {
        attachments: [],
        provider_native_tools: [],
        custom_tools: [],
        custom_tool_definitions: [],
        custom_tool_history: [],
        prompt: nil,
        messages: nil,
        system_instruction: nil,
        schema: nil,
        prompt_definition: nil,
        stream: false
      }.freeze

      module_function

      def for(request)
        {
          state: request.state,
          questions: request.questions,
          input_character_count: request.input_character_count,
          profile: request.profile,
          purpose: request.purpose,
          provider: request.provider,
          model: request.model,
          fallbacks: request.fallbacks,
          attribution: request.attribution,
          metadata: request.metadata,
          execution_deadline: request.execution_deadline
        }.merge(EMPTY_GENERATION_CHANNELS)
      end
    end
  end
end
