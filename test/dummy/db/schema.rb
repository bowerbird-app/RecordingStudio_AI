# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_08_11_130000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"
  enable_extension "pgcrypto"

  create_table "folders", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "name"
    t.datetime "updated_at", null: false
  end

  create_table "pages", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "title"
    t.datetime "updated_at", null: false
  end

  create_table "recording_studio_ai_attempts", force: :cascade do |t|
    t.json "attachment_content_types"
    t.integer "attachment_count", default: 0, null: false
    t.bigint "attachment_total_bytes", default: 0, null: false
    t.bigint "cached_input_tokens"
    t.integer "citation_count", default: 0, null: false
    t.datetime "completed_at"
    t.bigint "cost_amount_microunits"
    t.string "cost_currency"
    t.boolean "cost_estimated"
    t.string "cost_source"
    t.datetime "created_at", null: false
    t.string "error_category"
    t.string "error_code"
    t.string "error_message"
    t.string "finish_reason"
    t.bigint "input_tokens"
    t.string "kind", null: false
    t.bigint "latency_ms"
    t.integer "lock_version", default: 0, null: false
    t.json "metadata"
    t.string "model"
    t.bigint "output_tokens"
    t.string "profile_key"
    t.string "provider"
    t.integer "provider_file_count"
    t.string "provider_request_id"
    t.bigint "reasoning_tokens"
    t.boolean "retryable"
    t.bigint "run_id", null: false
    t.integer "sequence", null: false
    t.datetime "started_at"
    t.string "status", default: "pending", null: false
    t.boolean "streaming", default: false, null: false
    t.bigint "total_tokens"
    t.datetime "updated_at", null: false
    t.boolean "web_search_requested", default: false, null: false
    t.boolean "web_search_used", default: false, null: false
    t.index ["provider", "model", "created_at"], name: "idx_rsai_attempts_provider_model_created_at"
    t.index ["provider_request_id"], name: "index_recording_studio_ai_attempts_on_provider_request_id"
    t.index ["run_id", "sequence"], name: "index_recording_studio_ai_attempts_on_run_id_and_sequence", unique: true
    t.index ["run_id"], name: "index_recording_studio_ai_attempts_on_run_id"
    t.index ["status", "created_at"], name: "index_recording_studio_ai_attempts_on_status_and_created_at"
    t.check_constraint "(latency_ms IS NULL OR latency_ms >= 0) AND (input_tokens IS NULL OR input_tokens >= 0) AND (output_tokens IS NULL OR output_tokens >= 0) AND (total_tokens IS NULL OR total_tokens >= 0) AND (cached_input_tokens IS NULL OR cached_input_tokens >= 0) AND (reasoning_tokens IS NULL OR reasoning_tokens >= 0) AND (cost_amount_microunits IS NULL OR cost_amount_microunits >= 0)", name: "chk_rsai_attempts_nonnegative_metrics"
    t.check_constraint "completed_at IS NULL OR started_at IS NULL OR completed_at >= started_at", name: "chk_rsai_attempts_timeline"
    t.check_constraint "cost_source IS NULL OR (cost_source::text = ANY (ARRAY['provider'::character varying::text, 'catalog'::character varying::text, 'estimate'::character varying::text, 'unavailable'::character varying::text]))", name: "chk_rsai_attempts_cost_source"
    t.check_constraint "kind::text = ANY (ARRAY['primary'::character varying::text, 'retry'::character varying::text, 'fallback'::character varying::text, 'continuation'::character varying::text])", name: "chk_rsai_attempts_kind"
    t.check_constraint "sequence > 0 AND citation_count >= 0 AND attachment_count >= 0 AND attachment_total_bytes >= 0 AND (provider_file_count IS NULL OR provider_file_count >= 0)", name: "chk_rsai_attempts_nonnegative_counts"
    t.check_constraint "status::text = ANY (ARRAY['pending'::character varying::text, 'running'::character varying::text, 'completed'::character varying::text, 'failed'::character varying::text, 'cancelled'::character varying::text])", name: "chk_rsai_attempts_status"
  end

  create_table "recording_studio_ai_batch_items", force: :cascade do |t|
    t.bigint "batch_id", null: false
    t.bigint "cached_input_tokens"
    t.datetime "completed_at"
    t.bigint "cost_amount_microunits"
    t.string "cost_currency"
    t.boolean "cost_estimated"
    t.datetime "created_at", null: false
    t.string "error_category"
    t.string "error_code"
    t.string "error_message"
    t.string "finish_reason"
    t.bigint "input_tokens"
    t.integer "lock_version", default: 0, null: false
    t.json "metadata"
    t.bigint "output_tokens"
    t.integer "position", null: false
    t.string "provider_item_id"
    t.bigint "reasoning_tokens"
    t.string "reference", null: false
    t.bigint "run_id", null: false
    t.datetime "started_at"
    t.string "status", null: false
    t.bigint "total_tokens"
    t.datetime "updated_at", null: false
    t.index ["batch_id", "position"], name: "index_recording_studio_ai_batch_items_on_batch_id_and_position", unique: true
    t.index ["batch_id", "reference"], name: "idx_on_batch_id_reference_41f755821b", unique: true
    t.index ["provider_item_id"], name: "index_recording_studio_ai_batch_items_on_provider_item_id"
    t.index ["run_id"], name: "index_recording_studio_ai_batch_items_on_run_id", unique: true
    t.index ["status", "created_at"], name: "index_recording_studio_ai_batch_items_on_status_and_created_at"
    t.check_constraint "(input_tokens IS NULL OR input_tokens >= 0) AND (output_tokens IS NULL OR output_tokens >= 0) AND (total_tokens IS NULL OR total_tokens >= 0) AND (cached_input_tokens IS NULL OR cached_input_tokens >= 0) AND (reasoning_tokens IS NULL OR reasoning_tokens >= 0) AND (cost_amount_microunits IS NULL OR cost_amount_microunits >= 0)", name: "chk_rsai_batch_items_nonnegative_metrics"
    t.check_constraint "\"position\" >= 0", name: "chk_rsai_batch_items_position"
    t.check_constraint "completed_at IS NULL OR started_at IS NULL OR completed_at >= started_at", name: "chk_rsai_batch_items_timeline"
    t.check_constraint "status::text = ANY (ARRAY['pending'::character varying::text, 'processing'::character varying::text, 'completed'::character varying::text, 'failed'::character varying::text, 'cancelled'::character varying::text, 'expired'::character varying::text])", name: "chk_rsai_batch_items_status"
  end

  create_table "recording_studio_ai_batches", force: :cascade do |t|
    t.bigint "cached_input_tokens"
    t.integer "cancelled_item_count", default: 0, null: false
    t.datetime "completed_at"
    t.integer "completed_item_count", default: 0, null: false
    t.uuid "context_recording_id"
    t.string "correlation_id", null: false
    t.bigint "cost_amount_microunits"
    t.string "cost_currency"
    t.boolean "cost_estimated"
    t.datetime "created_at", null: false
    t.string "error_category"
    t.string "error_code"
    t.string "error_message"
    t.string "execution_source"
    t.string "executor_id"
    t.string "executor_kind"
    t.json "executor_snapshot"
    t.string "executor_type"
    t.datetime "expires_at"
    t.integer "failed_item_count", default: 0, null: false
    t.string "impersonator_id"
    t.json "impersonator_snapshot"
    t.string "impersonator_type"
    t.string "initiator_id", null: false
    t.string "initiator_kind", null: false
    t.json "initiator_snapshot"
    t.string "initiator_type", null: false
    t.bigint "input_tokens"
    t.integer "item_count", default: 0, null: false
    t.string "job_id"
    t.integer "lock_version", default: 0, null: false
    t.json "metadata"
    t.string "model"
    t.bigint "output_tokens"
    t.string "profile_key"
    t.string "provider"
    t.string "provider_batch_id"
    t.bigint "reasoning_tokens"
    t.string "request_id"
    t.uuid "root_recording_id", null: false
    t.string "status", null: false
    t.datetime "submitted_at"
    t.bigint "total_tokens"
    t.datetime "updated_at", null: false
    t.index ["context_recording_id"], name: "index_recording_studio_ai_batches_on_context_recording_id"
    t.index ["correlation_id"], name: "index_recording_studio_ai_batches_on_correlation_id", unique: true
    t.index ["expires_at"], name: "index_recording_studio_ai_batches_on_expires_at"
    t.index ["impersonator_type", "impersonator_id"], name: "idx_on_impersonator_type_impersonator_id_8de192b4a5"
    t.index ["initiator_type", "initiator_id"], name: "idx_on_initiator_type_initiator_id_b02d5c76ac"
    t.index ["job_id"], name: "index_recording_studio_ai_batches_on_job_id"
    t.index ["provider", "model", "created_at"], name: "idx_rsai_batches_provider_model_created_at"
    t.index ["provider_batch_id"], name: "index_recording_studio_ai_batches_on_provider_batch_id"
    t.index ["request_id"], name: "index_recording_studio_ai_batches_on_request_id"
    t.index ["root_recording_id", "created_at"], name: "idx_on_root_recording_id_created_at_42fdcd79d6"
    t.index ["root_recording_id"], name: "index_recording_studio_ai_batches_on_root_recording_id"
    t.index ["status", "created_at"], name: "index_recording_studio_ai_batches_on_status_and_created_at"
    t.check_constraint "(input_tokens IS NULL OR input_tokens >= 0) AND (output_tokens IS NULL OR output_tokens >= 0) AND (total_tokens IS NULL OR total_tokens >= 0) AND (cached_input_tokens IS NULL OR cached_input_tokens >= 0) AND (reasoning_tokens IS NULL OR reasoning_tokens >= 0) AND (cost_amount_microunits IS NULL OR cost_amount_microunits >= 0)", name: "chk_rsai_batches_nonnegative_metrics"
    t.check_constraint "completed_at IS NULL OR submitted_at IS NULL OR completed_at >= submitted_at", name: "chk_rsai_batches_timeline"
    t.check_constraint "completed_item_count <= item_count AND failed_item_count <= item_count AND cancelled_item_count <= item_count", name: "chk_rsai_batches_item_bounds"
    t.check_constraint "item_count >= 0 AND completed_item_count >= 0 AND failed_item_count >= 0 AND cancelled_item_count >= 0", name: "chk_rsai_batches_nonnegative_counts"
    t.check_constraint "status::text = ANY (ARRAY['preparing'::character varying::text, 'submitted'::character varying::text, 'processing'::character varying::text, 'completed'::character varying::text, 'partially_completed'::character varying::text, 'failed'::character varying::text, 'cancelled'::character varying::text, 'expired'::character varying::text])", name: "chk_rsai_batches_status"
  end

  create_table "recording_studio_ai_custom_tool_invocations", force: :cascade do |t|
    t.string "arguments_digest"
    t.text "arguments_summary"
    t.datetime "completed_at"
    t.string "confirmation_status"
    t.datetime "confirmed_at"
    t.string "confirmed_by_id"
    t.string "confirmed_by_type"
    t.bigint "continued_by_attempt_id"
    t.string "cost_category"
    t.datetime "created_at", null: false
    t.boolean "destructive", null: false
    t.string "error_category"
    t.string "error_code"
    t.string "error_message"
    t.boolean "idempotent", null: false
    t.string "latency_category"
    t.bigint "latency_ms"
    t.integer "lock_version", default: 0, null: false
    t.json "metadata"
    t.string "provider_tool_call_id"
    t.boolean "read_only", null: false
    t.bigint "requested_by_attempt_id"
    t.boolean "requires_confirmation", null: false
    t.string "result_digest"
    t.text "result_summary"
    t.bigint "run_id", null: false
    t.datetime "started_at"
    t.string "status", null: false
    t.string "tool_key", null: false
    t.string "tool_name_snapshot"
    t.integer "tool_version", null: false
    t.datetime "updated_at", null: false
    t.index ["confirmation_status", "created_at"], name: "idx_rsai_tool_invocations_confirmation"
    t.index ["continued_by_attempt_id"], name: "idx_rsai_tool_invocations_continued_attempt"
    t.index ["provider_tool_call_id"], name: "idx_on_provider_tool_call_id_c470d20051"
    t.index ["requested_by_attempt_id"], name: "idx_rsai_tool_invocations_requested_attempt"
    t.index ["run_id", "created_at"], name: "idx_rsai_tool_invocations_run_created_at"
    t.index ["run_id"], name: "index_recording_studio_ai_custom_tool_invocations_on_run_id"
    t.index ["status", "created_at"], name: "idx_on_status_created_at_3871597917"
    t.index ["tool_key", "created_at"], name: "idx_on_tool_key_created_at_f4175f8648"
    t.check_constraint "completed_at IS NULL OR started_at IS NULL OR completed_at >= started_at", name: "chk_rsai_tool_invocations_timeline"
    t.check_constraint "confirmation_status IS NULL OR (confirmation_status::text = ANY (ARRAY['not_required'::character varying::text, 'pending'::character varying::text, 'confirmed'::character varying::text, 'rejected'::character varying::text, 'expired'::character varying::text]))", name: "chk_rsai_tool_invocations_confirmation_status"
    t.check_constraint "confirmation_status::text = 'confirmed'::text AND confirmed_by_type IS NOT NULL AND confirmed_by_id IS NOT NULL AND confirmed_at IS NOT NULL OR confirmation_status::text <> 'confirmed'::text AND confirmed_by_type IS NULL AND confirmed_by_id IS NULL AND confirmed_at IS NULL OR confirmation_status IS NULL", name: "chk_rsai_tool_invocations_confirmer"
    t.check_constraint "cost_category IS NULL OR (cost_category::text = ANY (ARRAY['negligible'::character varying::text, 'low'::character varying::text, 'medium'::character varying::text, 'high'::character varying::text]))", name: "chk_rsai_tool_invocations_cost_category"
    t.check_constraint "latency_category IS NULL OR (latency_category::text = ANY (ARRAY['instant'::character varying::text, 'fast'::character varying::text, 'slow'::character varying::text]))", name: "chk_rsai_tool_invocations_latency_category"
    t.check_constraint "latency_ms IS NULL OR latency_ms >= 0", name: "chk_rsai_tool_invocations_latency"
    t.check_constraint "status::text = ANY (ARRAY['requested'::character varying::text, 'awaiting_confirmation'::character varying::text, 'authorized'::character varying::text, 'running'::character varying::text, 'completed'::character varying::text, 'denied'::character varying::text, 'rejected'::character varying::text, 'failed'::character varying::text, 'cancelled'::character varying::text])", name: "chk_rsai_tool_invocations_status"
  end

  create_table "recording_studio_ai_responses", force: :cascade do |t|
    t.bigint "attempt_id"
    t.bigint "batch_item_id"
    t.bigint "byte_size"
    t.boolean "complete"
    t.text "content_text"
    t.string "content_type"
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.string "finish_reason"
    t.json "metadata"
    t.string "model"
    t.text "normalized_response"
    t.string "provider"
    t.string "provider_response_id"
    t.text "raw_response"
    t.string "response_type", null: false
    t.boolean "truncated"
    t.datetime "updated_at", null: false
    t.index ["attempt_id"], name: "index_recording_studio_ai_responses_on_attempt_id", unique: true
    t.index ["batch_item_id"], name: "index_recording_studio_ai_responses_on_batch_item_id", unique: true
    t.index ["expires_at"], name: "index_recording_studio_ai_responses_on_expires_at"
    t.index ["provider", "model", "created_at"], name: "idx_rsai_responses_provider_model_created_at"
    t.index ["provider_response_id"], name: "index_recording_studio_ai_responses_on_provider_response_id"
    t.check_constraint "attempt_id IS NOT NULL AND batch_item_id IS NULL OR attempt_id IS NULL AND batch_item_id IS NOT NULL", name: "chk_rsai_responses_attempt_xor_batch_item"
    t.check_constraint "byte_size IS NULL OR byte_size >= 0", name: "chk_rsai_responses_nonnegative_byte_size"
    t.check_constraint "response_type::text = ANY (ARRAY['generation'::character varying::text, 'stream'::character varying::text, 'batch_item'::character varying::text, 'error'::character varying::text])", name: "chk_rsai_responses_type"
  end

  create_table "recording_studio_ai_runs", force: :cascade do |t|
    t.json "attachment_content_types"
    t.integer "attachment_count", default: 0, null: false
    t.bigint "attachment_total_bytes", default: 0, null: false
    t.integer "attempt_count", default: 0, null: false
    t.bigint "cached_input_tokens"
    t.integer "citation_count", default: 0, null: false
    t.datetime "completed_at"
    t.uuid "context_recording_id"
    t.string "correlation_id", null: false
    t.bigint "cost_amount_microunits"
    t.string "cost_currency"
    t.boolean "cost_estimated"
    t.datetime "created_at", null: false
    t.integer "custom_tool_invocation_count", default: 0, null: false
    t.string "error_category"
    t.string "error_code"
    t.string "error_message"
    t.string "execution_source"
    t.string "executor_id"
    t.string "executor_kind"
    t.json "executor_snapshot"
    t.string "executor_type"
    t.integer "fallback_count", default: 0, null: false
    t.string "impersonator_id"
    t.json "impersonator_snapshot"
    t.string "impersonator_type"
    t.string "initiator_id", null: false
    t.string "initiator_kind", null: false
    t.json "initiator_snapshot"
    t.string "initiator_type", null: false
    t.integer "input_character_count"
    t.string "input_digest"
    t.bigint "input_tokens"
    t.string "job_id"
    t.bigint "latency_ms"
    t.integer "lock_version", default: 0, null: false
    t.json "metadata"
    t.string "operation", null: false
    t.integer "output_character_count"
    t.string "output_digest"
    t.bigint "output_tokens"
    t.string "profile_key"
    t.string "purpose"
    t.bigint "reasoning_tokens"
    t.string "request_id"
    t.string "requested_provider"
    t.string "resolved_model"
    t.string "resolved_provider"
    t.integer "retry_count", default: 0, null: false
    t.uuid "root_recording_id", null: false
    t.datetime "started_at"
    t.string "status", default: "pending", null: false
    t.bigint "total_tokens"
    t.datetime "updated_at", null: false
    t.boolean "web_search_requested", default: false, null: false
    t.boolean "web_search_used", default: false, null: false
    t.index ["context_recording_id"], name: "index_recording_studio_ai_runs_on_context_recording_id"
    t.index ["correlation_id"], name: "index_recording_studio_ai_runs_on_correlation_id", unique: true
    t.index ["executor_type", "executor_id"], name: "idx_on_executor_type_executor_id_ff99c66eda"
    t.index ["initiator_type", "initiator_id"], name: "idx_on_initiator_type_initiator_id_c688e18770"
    t.index ["job_id"], name: "index_recording_studio_ai_runs_on_job_id"
    t.index ["profile_key", "created_at"], name: "index_recording_studio_ai_runs_on_profile_key_and_created_at"
    t.index ["purpose", "created_at"], name: "index_recording_studio_ai_runs_on_purpose_and_created_at"
    t.index ["request_id"], name: "index_recording_studio_ai_runs_on_request_id"
    t.index ["resolved_provider", "resolved_model", "created_at"], name: "idx_rsai_runs_provider_model_created_at"
    t.index ["root_recording_id", "created_at"], name: "idx_on_root_recording_id_created_at_22709d290f"
    t.index ["root_recording_id"], name: "index_recording_studio_ai_runs_on_root_recording_id"
    t.index ["status", "created_at"], name: "index_recording_studio_ai_runs_on_status_and_created_at"
    t.check_constraint "(latency_ms IS NULL OR latency_ms >= 0) AND (input_tokens IS NULL OR input_tokens >= 0) AND (output_tokens IS NULL OR output_tokens >= 0) AND (total_tokens IS NULL OR total_tokens >= 0) AND (cached_input_tokens IS NULL OR cached_input_tokens >= 0) AND (reasoning_tokens IS NULL OR reasoning_tokens >= 0) AND (cost_amount_microunits IS NULL OR cost_amount_microunits >= 0) AND (input_character_count IS NULL OR input_character_count >= 0) AND (output_character_count IS NULL OR output_character_count >= 0)", name: "chk_rsai_runs_nonnegative_metrics"
    t.check_constraint "attachment_count >= 0 AND attachment_total_bytes >= 0 AND citation_count >= 0", name: "chk_rsai_runs_nonnegative_attachment_counts"
    t.check_constraint "attempt_count >= 0 AND retry_count >= 0 AND fallback_count >= 0 AND custom_tool_invocation_count >= 0", name: "chk_rsai_runs_nonnegative_counts"
    t.check_constraint "completed_at IS NULL OR started_at IS NULL OR completed_at >= started_at", name: "chk_rsai_runs_timeline"
    t.check_constraint "operation::text = ANY (ARRAY['generation'::character varying::text, 'stream'::character varying::text, 'batch'::character varying::text])", name: "chk_rsai_runs_operation"
    t.check_constraint "status::text = ANY (ARRAY['pending'::character varying::text, 'running'::character varying::text, 'completed'::character varying::text, 'failed'::character varying::text, 'cancelled'::character varying::text])", name: "chk_rsai_runs_status"
  end

  create_table "recording_studio_events", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "action", null: false
    t.uuid "actor_id"
    t.string "actor_type"
    t.datetime "created_at", null: false
    t.string "idempotency_key"
    t.uuid "impersonator_id"
    t.string "impersonator_type"
    t.jsonb "metadata", default: {}, null: false
    t.datetime "occurred_at", default: -> { "CURRENT_TIMESTAMP" }, null: false
    t.uuid "previous_recordable_id"
    t.string "previous_recordable_type"
    t.uuid "recordable_id", null: false
    t.string "recordable_type", null: false
    t.uuid "recording_id", null: false
    t.index ["recording_id", "idempotency_key"], name: "index_recording_studio_events_on_recording_and_idempotency_key", unique: true, where: "(idempotency_key IS NOT NULL)"
    t.index ["recording_id"], name: "index_recording_studio_events_on_recording_id"
  end

  create_table "recording_studio_recordings", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "parent_recording_id"
    t.uuid "recordable_id", null: false
    t.string "recordable_type", null: false
    t.uuid "root_recording_id"
    t.datetime "trashed_at"
    t.datetime "updated_at", null: false
    t.index ["parent_recording_id"], name: "index_recording_studio_recordings_on_parent_recording_id"
    t.index ["recordable_type", "recordable_id", "parent_recording_id", "trashed_at"], name: "index_recording_studio_recordings_on_recordable_parent_trashed"
    t.index ["recordable_type", "recordable_id"], name: "index_recording_studio_recordings_on_recordable"
    t.index ["root_recording_id"], name: "index_rs_recordings_on_root_recording"
  end

  create_table "recording_studio_root_switchable_selections", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "actor_id"
    t.string "actor_type"
    t.datetime "created_at", null: false
    t.string "device_browser"
    t.string "device_key", null: false
    t.string "device_label"
    t.string "device_platform"
    t.string "device_type"
    t.datetime "last_used_at", null: false
    t.uuid "root_recording_id", null: false
    t.string "scope_key", null: false
    t.datetime "updated_at", null: false
    t.text "user_agent"
    t.index ["actor_type", "actor_id", "device_key", "scope_key"], name: "idx_rs_root_switchable_actor_device_scope", unique: true, where: "(actor_id IS NOT NULL)"
    t.index ["device_key", "scope_key"], name: "idx_rs_root_switchable_anonymous_device_scope", unique: true, where: "(actor_id IS NULL)"
    t.index ["root_recording_id"], name: "idx_rs_root_switchable_root_recording"
  end

  create_table "users", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "email", default: "", null: false
    t.string "encrypted_password", default: "", null: false
    t.datetime "remember_created_at"
    t.datetime "reset_password_sent_at"
    t.string "reset_password_token"
    t.datetime "updated_at", null: false
    t.index ["email"], name: "index_users_on_email", unique: true
    t.index ["reset_password_token"], name: "index_users_on_reset_password_token", unique: true
  end

  create_table "workspaces", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "name"
    t.datetime "updated_at", null: false
  end

  add_foreign_key "recording_studio_ai_attempts", "recording_studio_ai_runs", column: "run_id"
  add_foreign_key "recording_studio_ai_batch_items", "recording_studio_ai_batches", column: "batch_id"
  add_foreign_key "recording_studio_ai_batch_items", "recording_studio_ai_runs", column: "run_id"
  add_foreign_key "recording_studio_ai_batches", "recording_studio_recordings", column: "context_recording_id"
  add_foreign_key "recording_studio_ai_batches", "recording_studio_recordings", column: "root_recording_id"
  add_foreign_key "recording_studio_ai_custom_tool_invocations", "recording_studio_ai_attempts", column: "continued_by_attempt_id"
  add_foreign_key "recording_studio_ai_custom_tool_invocations", "recording_studio_ai_attempts", column: "requested_by_attempt_id"
  add_foreign_key "recording_studio_ai_custom_tool_invocations", "recording_studio_ai_runs", column: "run_id"
  add_foreign_key "recording_studio_ai_responses", "recording_studio_ai_attempts", column: "attempt_id"
  add_foreign_key "recording_studio_ai_responses", "recording_studio_ai_batch_items", column: "batch_item_id"
  add_foreign_key "recording_studio_ai_runs", "recording_studio_recordings", column: "context_recording_id"
  add_foreign_key "recording_studio_ai_runs", "recording_studio_recordings", column: "root_recording_id"
  add_foreign_key "recording_studio_events", "recording_studio_recordings", column: "recording_id"
  add_foreign_key "recording_studio_recordings", "recording_studio_recordings", column: "parent_recording_id"
  add_foreign_key "recording_studio_recordings", "recording_studio_recordings", column: "root_recording_id"
end
