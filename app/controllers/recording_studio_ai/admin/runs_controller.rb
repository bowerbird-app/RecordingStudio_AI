# frozen_string_literal: true

module RecordingStudioAI
  module Admin
    class RunsController < ApplicationController
      FILTERS = %i[
        status operation purpose profile_key resolved_provider resolved_model execution_source error_category
      ].freeze

      def index
        @runs = apply_filters(visible_runs).order(created_at: :desc).limit(100)
        @sensitive_roots = @admin_access.root_ids.index_with do |root_id|
          @admin_access.allowed?(:view_sensitive_execution, root_id: root_id, context: { collection: "runs" })
        end
      end

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

      def apply_filters(scope)
        FILTERS.each do |field|
          value = params[field]
          scope = scope.where(field => value) if value.present?
        end
        scope = scope.where(web_search_used: true) if params[:web_search] == "1"
        scope = scope.where(root_recording_id: params[:root_recording_id]) if params[:root_recording_id].present?
        if params[:context_recording_id].present?
          scope = scope.where(context_recording_id: params[:context_recording_id])
        end
        scope = scope.where(initiator_id: params[:initiator_id]) if params[:initiator_id].present?
        scope = scope.where(executor_id: params[:executor_id]) if params[:executor_id].present?
        scope = scope.where(created_at: parsed_time(:created_after)..) if parsed_time(:created_after)
        scope = scope.where(created_at: ..parsed_time(:created_before).end_of_day) if parsed_time(:created_before)
        scope = scope.where.not(error_category: nil) if params[:error] == "1"
        scope = scope.where(id: visible_attempts.where(streaming: true).select(:run_id)) if params[:streaming] == "1"
        scope = scope.where(id: visible_tool_invocations.select(:run_id)) if params[:custom_tool_use] == "1"
        if params[:custom_tool_key].present?
          scope = scope.where(id: visible_tool_invocations.where(tool_key: params[:custom_tool_key]).select(:run_id))
        end
        scope = scope.where(id: RecordingStudioAI::BatchItem.select(:run_id)) if params[:batch] == "1"
        if params[:retained_response] == "1"
          unexpired = [
            "recording_studio_ai_responses.expires_at IS NULL OR recording_studio_ai_responses.expires_at > ?", Time.current
          ]
          attempt_runs = visible_attempts.joins(:response).where(*unexpired).select(:run_id)
          batch_runs = RecordingStudioAI::BatchItem.joins(:response).where(*unexpired).select(:run_id)
          scope = scope.where(id: attempt_runs).or(scope.where(id: batch_runs))
        end
        if params[:minimum_duration_ms].present?
          scope = scope.where("latency_ms >= ?",
                              params[:minimum_duration_ms].to_i)
        end
        scope = scope.where("total_tokens >= ?", params[:minimum_tokens].to_i) if params[:minimum_tokens].present?
        apply_search(scope)
      end

      def apply_search(scope)
        return scope if params[:q].blank?

        query = "%#{ActiveRecord::Base.sanitize_sql_like(params[:q].to_s)}%"
        attempt_runs = visible_attempts.where("provider_request_id LIKE ?", query).select(:run_id)
        batch_runs = RecordingStudioAI::BatchItem.joins(:batch).merge(visible_batches)
                                                 .where(
                                                   "recording_studio_ai_batch_items.reference LIKE :query OR " \
                                                   "recording_studio_ai_batch_items.provider_item_id LIKE :query OR " \
                                                   "recording_studio_ai_batches.provider_batch_id LIKE :query",
                                                   query: query
                                                 ).select(:run_id)
        tool_runs = visible_tool_invocations.where("tool_key LIKE ?", query).select(:run_id)
        scope.where(
          "purpose LIKE :query OR error_code LIKE :query OR " \
          "request_id LIKE :query OR job_id LIKE :query OR id IN (:attempt_runs) OR " \
          "id IN (:batch_runs) OR id IN (:tool_runs)",
          query: query, attempt_runs: attempt_runs,
          batch_runs: batch_runs, tool_runs: tool_runs
        )
      end

      def parsed_time(key)
        Time.zone.parse(params[key].to_s) if params[key].present?
      rescue ArgumentError
        nil
      end
    end
  end
end
