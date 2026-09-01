# frozen_string_literal: true

module RecordingStudioAI
  module Admin
    class RunsController < ApplicationController
      def show
        @run = visible_runs.includes(:custom_tool_invocations, attempts: :response).find(params[:id])
        @sensitive = sensitive_access?(@run)
        @attempts = @run.attempts.sort_by(&:sequence)
        @tool_invocations = @run.custom_tool_invocations.sort_by(&:created_at)
        redact_sensitive_execution! unless @sensitive
      end

      private

      def redact_sensitive_execution!
        @run.metadata = {}
        @attempts.each do |attempt|
          attempt.assign_attributes(metadata: {}, error_category: nil, error_code: nil, error_message: nil)
        end
        @tool_invocations.each do |invocation|
          invocation.assign_attributes(metadata: {}, error_category: nil, error_code: nil, error_message: nil)
        end
      end
    end
  end
end
