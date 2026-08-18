# frozen_string_literal: true

module RecordingStudioAI
  module Admin
    class ApplicationController < ::ApplicationController
      before_action :run_admin_authenticate
      before_action :establish_admin_access

      rescue_from ActiveRecord::RecordNotFound, with: :render_not_found
      rescue_from RecordingStudioAI::Errors::ContractValidationError, with: :render_authorization_failure

      helper_method :sensitive_access?

      layout RecordingStudioAI.configuration.admin_layout if RecordingStudioAI.configuration.admin_layout.present?

      private

      # Optional host hook. The engine does not authenticate by itself — either
      # authenticate in ::ApplicationController or set config.admin_authenticate.
      def run_admin_authenticate
        handler = RecordingStudioAI.configuration.admin_authenticate
        return if handler.nil?

        handler.call(controller: self)
      end

      def establish_admin_access
        @admin_access = RecordingStudioAI::Admin::Access.new(controller: self)
      end

      def visible_runs
        RecordingStudioAI::Run.where(root_recording_id: @admin_access.root_ids)
      end

      def visible_attempts
        RecordingStudioAI::Attempt.joins(:run).merge(visible_runs)
      end

      def visible_tool_invocations
        RecordingStudioAI::CustomToolInvocation.joins(:run).merge(visible_runs)
      end

      def visible_batches
        RecordingStudioAI::Batch.where(root_recording_id: @admin_access.root_ids)
      end

      def sensitive_access?(record)
        @admin_access.allowed?(
          :view_sensitive_execution,
          root_id: record.root_recording_id,
          context: { record_type: record.class.name, record_id: record.id }
        )
      end

      def render_authorization_failure(error)
        raise error unless error.code == "authorization"

        head :not_found
      end

      def render_not_found
        head :not_found
      end
    end
  end
end
