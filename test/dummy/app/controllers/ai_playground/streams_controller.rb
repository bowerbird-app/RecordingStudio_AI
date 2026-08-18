# frozen_string_literal: true

module AIPlayground
  class StreamsController < AIPlaygroundController
    include ActionController::Live

    skip_before_action :authenticate_user!
    before_action :authenticate_live_session!

    def stream
      form = default_form.merge(form_params.to_h)
      request_id = SecureRandom.uuid
      root_recording = current_root_recording || RecordingStudio.root_recording_for(Workspace.order(:created_at).first)
      raise "No root recording is available for AI execution." if root_recording.nil?

      response.headers["Content-Type"] = "text/event-stream"
      response.headers["Cache-Control"] = "no-cache"
      response.headers["X-Accel-Buffering"] = "no"
      response.headers["Last-Modified"] = Time.current.httpdate
      write_stream_event(type: "started", request_id: request_id)

      RecordingStudioAI.generate(
        **generation_kwargs(form, root_recording: root_recording, request_id: request_id).merge(stream: true)
      ) do |event|
        text = event.text_delta.to_s if event.respond_to?(:text_delta)
        write_stream_event(type: "delta", text: text) if text.present?
      end
      write_stream_event(type: "complete")
    rescue StandardError => error
      write_stream_event(type: "error", message: "#{error.class}: #{error.message}")
    ensure
      response.stream.close
    end

    private

    # ActionController::Live runs the action in a separate thread, so Devise's
    # authenticate_user! throw(:warden) cannot be caught by Warden middleware.
    def authenticate_live_session!
      return if user_signed_in?

      head :unauthorized
    end

    def write_stream_event(payload)
      response.stream.write("data: #{JSON.generate(payload)}\n\n")
    end
  end
end
