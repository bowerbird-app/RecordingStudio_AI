# frozen_string_literal: true

module AdminScreens
  module RecordingStudioAIWidgets
    def responses_scope(context = admin_context)
      bind_admin_context!(context) if context
      run_ids = runs_scope(context).select(:id)
      attempt_ids = RecordingStudioAI::Attempt.where(run_id: run_ids).select(:id)
      batch_item_ids = RecordingStudioAI::BatchItem.where(run_id: run_ids).select(:id)

      RecordingStudioAI::Response.includes(attempt: :run, batch_item: :run).where(
        "recording_studio_ai_responses.attempt_id IN (:attempt_ids) OR " \
        "recording_studio_ai_responses.batch_item_id IN (:batch_item_ids)",
        attempt_ids: attempt_ids,
        batch_item_ids: batch_item_ids
      )
    end

    def response_run(row)
      row.attempt&.run || row.batch_item&.run
    end

    def saved_reply_listed?(row, context = admin_context)
      run = response_run(row)
      return false unless run

      runs_scope(context).where(id: run.id).exists?
    end

    def response_distinct_values(column)
      responses_scope.distinct.order(column).pluck(column).compact_blank
    end
  end
end
