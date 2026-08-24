# frozen_string_literal: true

require "timeout"
require "recording_studio_ai/orchestration"

module RecordingStudioAI
  class Orchestrator
    class StreamIdleTimeout < Timeout::Error; end
    class ProviderRequestTimeout < Timeout::Error; end

    class StreamConsumerError < StandardError
      attr_reader :original_error

      def initialize(original_error)
        @original_error = original_error
        super("Stream consumer failed")
      end
    end

    PlannedCandidate = Orchestration::PlannedCandidate
    ExecutedAttempt = Orchestration::ExecutedAttempt
    CancellationState = Orchestration::CancellationState
    CustomToolContext = Orchestration::CustomToolContext

    def initialize(configuration: RecordingStudioAI.configuration)
      @configuration = configuration
      @planner = Orchestration::Planner.new(configuration: configuration)
      @persistence = Orchestration::Persistence.new(configuration: configuration)
      @response_builder = Orchestration::ResponseBuilder.new(persistence: @persistence)
    end

    def generate(request)
      request = request.merge(execution_deadline: Time.current + @configuration.total_execution_timeout)
      execute(request, operation: :generation, stream_session: nil)
    end

    def stream(request, &event_handler)
      request = request.merge(execution_deadline: Time.current + @configuration.total_execution_timeout)
      stream_session = Orchestration::StreamSession.new(event_handler: event_handler)
      completed = false
      response = execute(request, operation: :stream, stream_session: stream_session)
      stream_session.emit_final(response)
      completed = true
      response
    rescue StreamConsumerError => e
      stream_session.cancel_records!
      raise e.original_error
    ensure
      stream_session&.cancel_records! unless completed
    end

    private

    def execute(request, operation:, stream_session:)
      plan = @planner.plan(request, operation: operation)
      run = @persistence.create_run!(request, plan.first.candidate, operation: operation)
      stream_session&.active_run = run if operation == :stream
      executions = plan_executor(stream_session).execute(run, request, plan, operation: operation)
      return @persistence.complete_deadline_failure(request, run, operation: operation) if executions.empty?

      final_execution = executions.last
      @persistence.complete_run!(run, executions, final_execution)
      @response_builder.build(request, run, executions, final_execution, operation: operation)
    rescue RecordingStudioAI::Errors::ResolutionError => e
      @response_builder.resolution_failure(request, e, operation: operation)
    end

    def plan_executor(stream_session)
      attempt_runner = Orchestration::AttemptRunner.new(
        configuration: @configuration, stream_session: stream_session
      )
      custom_tools = Orchestration::CustomTools.new(
        configuration: @configuration,
        persistence: @persistence,
        attempt_runner: attempt_runner,
        stream_session: stream_session
      )
      Orchestration::PlanExecutor.new(
        configuration: @configuration,
        persistence: @persistence,
        attempt_runner: attempt_runner,
        custom_tools: custom_tools,
        stream_session: stream_session
      )
    end
  end
end
