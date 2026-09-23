# frozen_string_literal: true

module RecordingStudioAI
  module Orchestration
    # Internal hash for the execution spine. It carries the typed decision
    # fields the planner and persistence read. Generation channels are absent;
    # a missing attachment or tool list is empty.
    module DecisionExecution
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
        }
      end
    end
  end
end
