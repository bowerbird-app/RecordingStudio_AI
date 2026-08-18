# frozen_string_literal: true

module RecordingStudioAI
  module Admin
    class RetainedResponsesController < ApplicationController
      skip_before_action :establish_admin_access, if: :recording_studio_admin_available?
      before_action :authorize_recording_studio_admin!, if: :recording_studio_admin_available?

      def show
        retained, run = load_retained_response!
        authorize_engine_sensitive_execution!(retained, run) unless recording_studio_admin_available?
        @response = decrypt_retained_response(retained)
        @run = run
      end

      private

      def load_retained_response!
        retained = attempt_response || batch_item_response
        raise ActiveRecord::RecordNotFound, "retained response is outside the visible roots" unless retained

        run = retained.attempt&.run || retained.batch_item&.run
        raise ActiveRecord::RecordNotFound, "retained response owner is unavailable" unless run

        [retained, run]
      end

      def attempt_response
        RecordingStudioAI::Response.joins(attempt: :run).merge(visible_runs).find_by(id: params[:id])
      end

      def batch_item_response
        RecordingStudioAI::Response.joins(batch_item: :run).merge(visible_runs).find_by(id: params[:id])
      end

      def visible_runs
        return super unless recording_studio_admin_available?

        root = @recording_studio_admin_context.root_recording
        raise ActiveRecord::RecordNotFound, "admin root is unavailable" unless root

        RecordingStudioAI::Run.where(root_recording_id: root.id)
      end

      def authorize_engine_sensitive_execution!(retained, run)
        @admin_access.authorize!(
          :view_sensitive_execution,
          root_id: run.root_recording_id,
          context: { response_id: retained.id, run_id: run.id }
        )
      end

      def decrypt_retained_response(retained)
        RecordingStudioAI::ResponseReader.new.read(
          response: retained,
          initiator: retained_response_initiator,
          execution_source: :admin,
          preauthorized: recording_studio_admin_available?
        )
      end

      def retained_response_initiator
        if recording_studio_admin_available?
          @recording_studio_admin_context.current_actor
        else
          @admin_access.actor
        end
      end

      def recording_studio_admin_available?
        RecordingStudioAI::RecordingStudioAdminAuthorization.available?
      end

      def authorize_recording_studio_admin!
        context = RecordingStudioAI::RecordingStudioAdminAuthorization.context_for(controller: self)
        RecordingStudioAI::RecordingStudioAdminAuthorization.authorize!(context)
        @recording_studio_admin_context = context
      rescue RecordingStudioAdmin::AuthorizationFailed
        head :forbidden
      end
    end
  end
end
