# frozen_string_literal: true

module RecordingStudioAI
  class ResponseReader
    def initialize(configuration: RecordingStudioAI.configuration)
      @configuration = configuration
    end

    def read(response:, initiator:, initiator_kind: nil, executor: nil, execution_source: nil)
      if response.expires_at && response.expires_at <= Time.current
        raise ActiveRecord::RecordNotFound, "retained response has expired"
      end

      run = response.attempt&.run || response.batch_item&.run
      raise ActiveRecord::RecordNotFound, "retained response owner is missing" unless run

      attribution = Contracts::Attribution.new(
        root_recording: RecordingStudio::Recording.find(run.root_recording_id),
        initiator: initiator,
        initiator_kind: initiator_kind,
        executor: executor,
        execution_source: execution_source
      )
      Authorization.authorize!(
        :view_retained_response,
        attribution: attribution,
        context: { response_id: response.id, run_id: run.id }
      )

      {
        id: response.id,
        response_type: response.response_type,
        raw_response: parse_json(response.raw_response),
        normalized_response: parse_json(response.normalized_response),
        content_text: response.content_text,
        content_type: response.content_type,
        complete: response.complete,
        truncated: response.truncated,
        byte_size: response.byte_size,
        expires_at: response.expires_at
      }
    end

    private

    def parse_json(value) = value.nil? ? nil : JSON.parse(value)
  end
end