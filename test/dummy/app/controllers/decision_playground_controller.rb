# frozen_string_literal: true

class DecisionPlaygroundController < ApplicationController
  def show
    @form = DecisionPlayground::Form.seed
  end

  def create
    @form = DecisionPlayground::Form.parse(form_params)
    @request_id = SecureRandom.uuid
    root_recording = playground_root_recording!
    @response = RecordingStudioAI.decide(**@form.to_decide_kwargs(
      root_recording: root_recording,
      initiator: current_user,
      request_id: @request_id
    ))
    @response_payload = @response.to_h
    load_created_records!(@request_id)
    render :show
  rescue StandardError => error
    @form ||= DecisionPlayground::Form.seed
    @error_message = playground_error_message(error)
    load_created_records!(@request_id)
    render :show, status: :unprocessable_entity
  end

  private

  def playground_error_message(error)
    return error.message if error.is_a?(RecordingStudioAI::Errors::ContractValidationError)

    Rails.logger.error(
      "[decision_playground] #{error.class}: #{error.message}\n#{Array(error.backtrace).first(8).join("\n")}"
    )
    "That run didn't finish. Try again in a moment."
  end

  def load_created_records!(request_id)
    return if request_id.blank?

    @created_runs = RecordingStudioAI::Run.where(request_id: request_id).order(created_at: :desc)
    @created_attempts = RecordingStudioAI::Attempt.joins(:run)
      .where(recording_studio_ai_runs: { request_id: request_id })
      .order(created_at: :desc)
  end

  def form_params
    params.require(:decision_playground).permit(
      :state, :profile, :model, questions: [ :key, :type, :instructions, :criteria_text ]
    )
  end
end
