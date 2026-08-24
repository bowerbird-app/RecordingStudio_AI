# frozen_string_literal: true

module RecordingStudioAI
  class HistoryCleanup
    Result = Data.define(:responses, :tool_invocations, :attempts, :batch_items, :runs, :batches)

    def self.call(now: Time.current, retention_period: RecordingStudioAI.configuration.execution_history_retention_period)
      return Result.new(responses: 0, tool_invocations: 0, attempts: 0, batch_items: 0, runs: 0, batches: 0) unless retention_period

      cutoff = now - retention_period
      counts = Hash.new(0)
      ApplicationRecord.transaction do
        blocked_batch_ids = BatchItem.where.not(status: BatchItem.terminal_statuses).select(:batch_id)
        blocked_batch_run_ids = BatchItem.joins(:run).where.not(
          recording_studio_ai_runs: { status: Run.terminal_statuses }
        ).select(:batch_id)
        batch_ids = Batch.where(status: Batch.terminal_statuses).where(completed_at: ...cutoff)
          .where.not(id: blocked_batch_ids).where.not(id: blocked_batch_run_ids).lock.pluck(:id)
        batch_item_ids = BatchItem.where(batch_id: batch_ids).lock.pluck(:id)
        retained_batch_run_ids = BatchItem.where.not(batch_id: batch_ids).select(:run_id)
        blocked_attempt_run_ids = Attempt.where.not(status: Attempt.terminal_statuses).select(:run_id)
        blocked_tool_run_ids = CustomToolInvocation.where.not(
          status: CustomToolInvocation.terminal_statuses
        ).select(:run_id)
        run_ids = Run.where(status: Run.terminal_statuses).where(completed_at: ...cutoff)
          .where.not(id: retained_batch_run_ids).where.not(id: blocked_attempt_run_ids)
          .where.not(id: blocked_tool_run_ids).lock.pluck(:id)
        attempt_ids = Attempt.where(run_id: run_ids).lock.pluck(:id)

        counts[:responses] += Response.where(batch_item_id: batch_item_ids).delete_all
        counts[:responses] += Response.where(attempt_id: attempt_ids).delete_all
        counts[:tool_invocations] = CustomToolInvocation.where(run_id: run_ids).delete_all
        counts[:attempts] = Attempt.where(id: attempt_ids).delete_all
        counts[:batch_items] = BatchItem.where(id: batch_item_ids).delete_all
        counts[:runs] = Run.where(id: run_ids).delete_all
        counts[:batches] = Batch.where(id: batch_ids).delete_all
      end

      Result.new(**counts)
    end
  end
end
