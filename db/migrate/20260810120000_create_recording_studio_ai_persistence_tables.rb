# frozen_string_literal: true

class CreateRecordingStudioAIPersistenceTables < ActiveRecord::Migration[8.1]
  def change
    recording_id_type = connection.columns(:recording_studio_recordings).find { |column| column.name == "id" }.type

    create_table :recording_studio_ai_runs do |t|
      t.string :operation, null: false
      t.string :purpose
      t.string :status, null: false, default: "pending"
      t.string :profile_key
      t.string :requested_provider
      t.string :resolved_provider
      t.string :resolved_model

      t.references :root_recording, type: recording_id_type, null: false, index: false,
                foreign_key: { to_table: :recording_studio_recordings }
      t.references :context_recording, type: recording_id_type, index: false,
                   foreign_key: { to_table: :recording_studio_recordings }

      t.string :initiator_type, null: false
      t.string :initiator_id, null: false
      t.string :initiator_kind, null: false

      t.string :executor_type
      t.string :executor_id
      t.string :executor_kind

      t.string :impersonator_type
      t.string :impersonator_id

      t.string :execution_source
      t.string :request_id
      t.string :job_id
      t.string :correlation_id, null: false

      t.datetime :started_at
      t.datetime :completed_at
      t.bigint :latency_ms

      t.bigint :input_tokens
      t.bigint :output_tokens
      t.bigint :total_tokens
      t.bigint :cached_input_tokens
      t.bigint :reasoning_tokens

      t.integer :attempt_count, null: false, default: 0
      t.integer :retry_count, null: false, default: 0
      t.integer :fallback_count, null: false, default: 0
      t.integer :custom_tool_invocation_count, null: false, default: 0

      t.integer :input_character_count
      t.integer :output_character_count

      t.integer :attachment_count, null: false, default: 0
      t.bigint :attachment_total_bytes, null: false, default: 0
      t.json :attachment_content_types
      t.integer :citation_count, null: false, default: 0
      t.boolean :web_search_requested, null: false, default: false
      t.boolean :web_search_used, null: false, default: false

      t.string :error_category
      t.string :error_code
      t.string :error_message
      t.json :metadata

      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end

    add_index :recording_studio_ai_runs, :correlation_id, unique: true
    add_index :recording_studio_ai_runs, :request_id
    add_index :recording_studio_ai_runs, :job_id
    add_index :recording_studio_ai_runs, :root_recording_id
    add_index :recording_studio_ai_runs, :context_recording_id
    add_index :recording_studio_ai_runs, %i[initiator_type initiator_id]
    add_index :recording_studio_ai_runs, %i[executor_type executor_id]
    add_index :recording_studio_ai_runs, %i[root_recording_id created_at]
    add_index :recording_studio_ai_runs, %i[status created_at]
    add_index :recording_studio_ai_runs, %i[resolved_provider resolved_model created_at],
              name: "idx_rsai_runs_provider_model_created_at"
    add_index :recording_studio_ai_runs, %i[profile_key created_at]
    add_index :recording_studio_ai_runs, %i[purpose created_at]

    add_check_constraint :recording_studio_ai_runs,
                         "status IN ('pending','running','completed','failed','cancelled')",
                         name: "chk_rsai_runs_status"
    add_check_constraint :recording_studio_ai_runs,
                         "attempt_count >= 0 AND retry_count >= 0 AND fallback_count >= 0 AND custom_tool_invocation_count >= 0",
                         name: "chk_rsai_runs_nonnegative_counts"
    add_check_constraint :recording_studio_ai_runs,
                         "attachment_count >= 0 AND attachment_total_bytes >= 0 AND citation_count >= 0",
                         name: "chk_rsai_runs_nonnegative_attachment_counts"
    add_check_constraint :recording_studio_ai_runs,
                         "(latency_ms IS NULL OR latency_ms >= 0) AND (input_tokens IS NULL OR input_tokens >= 0) AND " \
                         "(output_tokens IS NULL OR output_tokens >= 0) AND (total_tokens IS NULL OR total_tokens >= 0) AND " \
                         "(cached_input_tokens IS NULL OR cached_input_tokens >= 0) AND (reasoning_tokens IS NULL OR reasoning_tokens >= 0) AND " \
                         "(input_character_count IS NULL OR input_character_count >= 0) AND " \
                         "(output_character_count IS NULL OR output_character_count >= 0)",
                         name: "chk_rsai_runs_nonnegative_metrics"

    create_table :recording_studio_ai_attempts do |t|
      t.references :run, null: false, foreign_key: { to_table: :recording_studio_ai_runs }
      t.integer :sequence, null: false
      t.string :kind, null: false
      t.string :status, null: false, default: "pending"
      t.string :profile_key
      t.string :provider
      t.string :model
      t.string :provider_request_id
      t.boolean :streaming, null: false, default: false

      t.datetime :started_at
      t.datetime :completed_at
      t.bigint :latency_ms

      t.bigint :input_tokens
      t.bigint :output_tokens
      t.bigint :total_tokens
      t.bigint :cached_input_tokens
      t.bigint :reasoning_tokens

      t.string :finish_reason
      t.boolean :retryable

      t.boolean :web_search_requested, null: false, default: false
      t.boolean :web_search_used, null: false, default: false
      t.integer :citation_count, null: false, default: 0

      t.integer :attachment_count, null: false, default: 0
      t.bigint :attachment_total_bytes, null: false, default: 0
      t.json :attachment_content_types
      t.integer :provider_file_count

      t.string :error_category
      t.string :error_code
      t.string :error_message
      t.json :metadata

      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end

    add_index :recording_studio_ai_attempts, %i[run_id sequence], unique: true
    add_index :recording_studio_ai_attempts, %i[provider model created_at],
              name: "idx_rsai_attempts_provider_model_created_at"
    add_index :recording_studio_ai_attempts, %i[status created_at]
    add_index :recording_studio_ai_attempts, :provider_request_id

    add_check_constraint :recording_studio_ai_attempts,
                         "kind IN ('primary','retry','fallback','continuation')",
                         name: "chk_rsai_attempts_kind"
    add_check_constraint :recording_studio_ai_attempts,
                         "status IN ('pending','running','completed','failed','cancelled')",
                         name: "chk_rsai_attempts_status"
    add_check_constraint :recording_studio_ai_attempts,
                         "sequence > 0 AND citation_count >= 0 AND attachment_count >= 0 AND attachment_total_bytes >= 0 AND " \
                         "(provider_file_count IS NULL OR provider_file_count >= 0)",
                         name: "chk_rsai_attempts_nonnegative_counts"
    add_check_constraint :recording_studio_ai_attempts,
                         "(latency_ms IS NULL OR latency_ms >= 0) AND (input_tokens IS NULL OR input_tokens >= 0) AND " \
                         "(output_tokens IS NULL OR output_tokens >= 0) AND (total_tokens IS NULL OR total_tokens >= 0) AND " \
                         "(cached_input_tokens IS NULL OR cached_input_tokens >= 0) AND (reasoning_tokens IS NULL OR reasoning_tokens >= 0) AND " \
                         "(latency_ms IS NULL OR latency_ms >= 0)",
                         name: "chk_rsai_attempts_nonnegative_metrics"

    create_table :recording_studio_ai_custom_tool_invocations do |t|
      t.references :run, null: false, foreign_key: { to_table: :recording_studio_ai_runs }
      t.references :requested_by_attempt, index: false, foreign_key: { to_table: :recording_studio_ai_attempts }
      t.references :continued_by_attempt, index: false, foreign_key: { to_table: :recording_studio_ai_attempts }
      t.string :provider_tool_call_id

      t.string :tool_key, null: false
      t.integer :tool_version, null: false
      t.string :tool_name_snapshot

      t.string :status, null: false
      t.boolean :read_only, null: false
      t.boolean :destructive, null: false
      t.boolean :requires_confirmation, null: false
      t.boolean :idempotent, null: false
      t.string :latency_category

      t.string :confirmation_status
      t.string :confirmed_by_type
      t.string :confirmed_by_id
      t.datetime :confirmed_at

      t.text :result_summary

      t.datetime :started_at
      t.datetime :completed_at
      t.bigint :latency_ms

      t.string :error_category
      t.string :error_code
      t.string :error_message
      t.json :metadata

      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end

    add_index :recording_studio_ai_custom_tool_invocations, %i[run_id created_at],
              name: "idx_rsai_tool_invocations_run_created_at"
    add_index :recording_studio_ai_custom_tool_invocations, %i[tool_key created_at]
    add_index :recording_studio_ai_custom_tool_invocations, %i[status created_at]
    add_index :recording_studio_ai_custom_tool_invocations, :requested_by_attempt_id,
              name: "idx_rsai_tool_invocations_requested_attempt"
    add_index :recording_studio_ai_custom_tool_invocations, :continued_by_attempt_id,
              name: "idx_rsai_tool_invocations_continued_attempt"
    add_index :recording_studio_ai_custom_tool_invocations, :provider_tool_call_id
    add_index :recording_studio_ai_custom_tool_invocations, %i[confirmation_status created_at],
              name: "idx_rsai_tool_invocations_confirmation"

    add_check_constraint :recording_studio_ai_custom_tool_invocations,
                         "status IN ('requested','awaiting_confirmation','authorized','running','completed','denied','rejected','failed','cancelled')",
                         name: "chk_rsai_tool_invocations_status"
    add_check_constraint :recording_studio_ai_custom_tool_invocations,
                         "(latency_ms IS NULL OR latency_ms >= 0)",
                         name: "chk_rsai_tool_invocations_latency"

    create_table :recording_studio_ai_batches do |t|
      t.string :status, null: false
      t.string :profile_key
      t.string :provider
      t.string :model
      t.string :provider_batch_id

      t.references :root_recording, type: recording_id_type, null: false,
                foreign_key: { to_table: :recording_studio_recordings }
      t.references :context_recording, type: recording_id_type,
                   foreign_key: { to_table: :recording_studio_recordings }

      t.string :initiator_type, null: false
      t.string :initiator_id, null: false
      t.string :initiator_kind, null: false

      t.string :executor_type
      t.string :executor_id
      t.string :executor_kind

      t.string :execution_source
      t.string :request_id
      t.string :job_id
      t.string :correlation_id, null: false

      t.integer :item_count, null: false, default: 0
      t.integer :completed_item_count, null: false, default: 0
      t.integer :failed_item_count, null: false, default: 0
      t.integer :cancelled_item_count, null: false, default: 0

      t.bigint :input_tokens
      t.bigint :output_tokens
      t.bigint :total_tokens
      t.bigint :cached_input_tokens
      t.bigint :reasoning_tokens

      t.datetime :submitted_at
      t.datetime :completed_at
      t.datetime :expires_at

      t.string :error_category
      t.string :error_code
      t.string :error_message
      t.json :metadata

      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end

    add_index :recording_studio_ai_batches, :correlation_id, unique: true
    add_index :recording_studio_ai_batches, :provider_batch_id
    add_index :recording_studio_ai_batches, %i[root_recording_id created_at]
    add_index :recording_studio_ai_batches, %i[initiator_type initiator_id]
    add_index :recording_studio_ai_batches, %i[status created_at]
    add_index :recording_studio_ai_batches, %i[provider model created_at],
              name: "idx_rsai_batches_provider_model_created_at"
    add_index :recording_studio_ai_batches, :expires_at
    add_index :recording_studio_ai_batches, :request_id
    add_index :recording_studio_ai_batches, :job_id

    add_check_constraint :recording_studio_ai_batches,
                         "status IN ('preparing','submitted','processing','completed','partially_completed','failed','cancelled','expired')",
                         name: "chk_rsai_batches_status"
    add_check_constraint :recording_studio_ai_batches,
                         "item_count >= 0 AND completed_item_count >= 0 AND failed_item_count >= 0 AND cancelled_item_count >= 0",
                         name: "chk_rsai_batches_nonnegative_counts"
    add_check_constraint :recording_studio_ai_batches,
                         "completed_item_count <= item_count AND failed_item_count <= item_count AND cancelled_item_count <= item_count",
                         name: "chk_rsai_batches_item_bounds"
    add_check_constraint :recording_studio_ai_batches,
                         "(input_tokens IS NULL OR input_tokens >= 0) AND (output_tokens IS NULL OR output_tokens >= 0) AND " \
                         "(total_tokens IS NULL OR total_tokens >= 0) AND (cached_input_tokens IS NULL OR cached_input_tokens >= 0) AND " \
                         "(reasoning_tokens IS NULL OR reasoning_tokens >= 0)",
                         name: "chk_rsai_batches_nonnegative_metrics"

    create_table :recording_studio_ai_batch_items do |t|
      t.references :batch, null: false, index: false, foreign_key: { to_table: :recording_studio_ai_batches }
      t.references :run, null: false, index: false, foreign_key: { to_table: :recording_studio_ai_runs }
      t.integer :position, null: false
      t.string :reference, null: false
      t.string :status, null: false
      t.string :provider_item_id

      t.datetime :started_at
      t.datetime :completed_at

      t.bigint :input_tokens
      t.bigint :output_tokens
      t.bigint :total_tokens
      t.bigint :cached_input_tokens
      t.bigint :reasoning_tokens

      t.string :finish_reason
      t.string :error_category
      t.string :error_code
      t.string :error_message
      t.json :metadata

      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end

    add_index :recording_studio_ai_batch_items, %i[batch_id position], unique: true
    add_index :recording_studio_ai_batch_items, %i[batch_id reference], unique: true
    add_index :recording_studio_ai_batch_items, :run_id, unique: true
    add_index :recording_studio_ai_batch_items, %i[status created_at]
    add_index :recording_studio_ai_batch_items, :provider_item_id

    add_check_constraint :recording_studio_ai_batch_items,
                         "status IN ('pending','processing','completed','failed','cancelled','expired')",
                         name: "chk_rsai_batch_items_status"
    add_check_constraint :recording_studio_ai_batch_items,
                         "position >= 0",
                         name: "chk_rsai_batch_items_position"
    add_check_constraint :recording_studio_ai_batch_items,
                         "(input_tokens IS NULL OR input_tokens >= 0) AND (output_tokens IS NULL OR output_tokens >= 0) AND " \
                         "(total_tokens IS NULL OR total_tokens >= 0) AND (cached_input_tokens IS NULL OR cached_input_tokens >= 0) AND " \
                         "(reasoning_tokens IS NULL OR reasoning_tokens >= 0)",
                         name: "chk_rsai_batch_items_nonnegative_metrics"

    create_table :recording_studio_ai_responses do |t|
      t.references :attempt, index: false, foreign_key: { to_table: :recording_studio_ai_attempts }
      t.references :batch_item, index: false, foreign_key: { to_table: :recording_studio_ai_batch_items }

      t.string :provider
      t.string :model
      t.string :provider_response_id
      t.string :response_type, null: false

      t.text :raw_response
      t.text :normalized_response
      t.text :content_text

      t.string :content_type
      t.string :finish_reason
      t.boolean :complete
      t.boolean :truncated
      t.bigint :byte_size
      t.datetime :expires_at
      t.json :metadata

      t.timestamps
    end

    add_index :recording_studio_ai_responses, :attempt_id, unique: true
    add_index :recording_studio_ai_responses, :batch_item_id, unique: true
    add_index :recording_studio_ai_responses, :provider_response_id
    add_index :recording_studio_ai_responses, :expires_at
    add_index :recording_studio_ai_responses, %i[provider model created_at],
              name: "idx_rsai_responses_provider_model_created_at"

    add_check_constraint :recording_studio_ai_responses,
                         "response_type IN ('generation','stream','batch_item','error')",
                         name: "chk_rsai_responses_type"
    add_check_constraint :recording_studio_ai_responses,
                         "(attempt_id IS NOT NULL AND batch_item_id IS NULL) OR (attempt_id IS NULL AND batch_item_id IS NOT NULL)",
                         name: "chk_rsai_responses_attempt_xor_batch_item"
    add_check_constraint :recording_studio_ai_responses,
                         "(byte_size IS NULL OR byte_size >= 0)",
                         name: "chk_rsai_responses_nonnegative_byte_size"
  end
end
