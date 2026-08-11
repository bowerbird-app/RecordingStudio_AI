# frozen_string_literal: true

module RecordingStudioAI
  module Admin
    class RetainedResponsesController < ApplicationController
      def show
        response = attempt_response || batch_item_response
        raise ActiveRecord::RecordNotFound, "retained response is outside the visible roots" unless response

        run = response.attempt&.run || response.batch_item&.run
        raise ActiveRecord::RecordNotFound, "retained response owner is unavailable" unless run

        @admin_access.authorize!(
          :view_sensitive_execution,
          root_id: run.root_recording_id,
          context: { response_id: response.id, run_id: run.id }
        )
        @response = RecordingStudioAI::ResponseReader.new.read(response: response, initiator: @admin_access.actor, execution_source: :admin)
        @run = run
      end

      private

      def attempt_response
        RecordingStudioAI::Response.joins(attempt: :run).merge(visible_runs).find_by(id: params[:id])
      end

      def batch_item_response
        RecordingStudioAI::Response.joins(batch_item: :run).merge(visible_runs).find_by(id: params[:id])
      end
    end
  end
end
