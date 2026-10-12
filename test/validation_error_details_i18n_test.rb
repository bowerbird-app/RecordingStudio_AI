# frozen_string_literal: true

require "test_helper"
require_relative "support/i18n_backend_isolation"

# Wave 2 left all six integrity errors.add sites untranslated (byte-identical to
# main). ActiveModel 8.1 ignores message: for String types, so translating later
# must pass Copy.t(..., default: "<main English>") as the type itself. These
# tests lock errors.details under :en and a non-English locale.
class ValidationErrorDetailsI18nTest < RecordingStudioAI::Test::PersistenceCase
  def persistence_schema
    :hardened
  end

  MAIN_DETAILS = {
    requested_by_attempt_id: [{ error: "must belong to the same run" }],
    continued_by_attempt_id: [{ error: "must belong to the same run" }],
    batch_run_id: [
      { error: "must belong to the batch root" },
      { error: "must use the batch context" }
    ],
    response_base: [{ error: "exactly one of attempt_id or batch_item_id must be present" }],
    terminal_base: [{ error: "Cannot modify terminal fields after status is terminal: resolved_provider" }]
  }.freeze

  def test_integrity_errors_details_match_main_under_english
    assert_equal MAIN_DETAILS, capture_integrity_error_details!
  end

  def test_integrity_errors_details_match_main_under_non_english_locale
    I18nBackendIsolation.with_snapshot do
      I18n.available_locales = I18n.available_locales | [:zz]
      I18n.backend.store_translations(:zz, {
                                        recording_studio: {
                                          ai: {
                                            admin: {
                                              section: { title: "Studio IA" }
                                            }
                                          }
                                        }
                                      })

      details = I18n.with_locale(:zz) { capture_integrity_error_details! }
      assert_equal MAIN_DETAILS, details
    end
  end

  private

  def capture_integrity_error_details!
    first_root = create_recording_id
    second_root = create_recording_id
    first_context = create_recording_id
    second_context = create_recording_id

    first_run = RecordingStudioAI::Run.create!(
      operation: "generation", status: "pending", root_recording_id: first_root,
      context_recording_id: first_context,
      initiator_type: "User", initiator_id: "user-1", initiator_kind: "user"
    )
    second_run = RecordingStudioAI::Run.create!(
      operation: "batch", status: "pending", root_recording_id: second_root,
      context_recording_id: second_context,
      initiator_type: "User", initiator_id: "user-1", initiator_kind: "user"
    )
    first_attempt = first_run.attempts.create!(sequence: 1, kind: "primary", status: "pending")

    invocation = second_run.custom_tool_invocations.new(
      requested_by_attempt: first_attempt,
      continued_by_attempt: first_attempt,
      tool_key: "lookup",
      tool_version: 1,
      status: "requested",
      read_only: true,
      destructive: false,
      requires_confirmation: false,
      idempotent: true
    )
    refute invocation.valid?

    batch = RecordingStudioAI::Batch.create!(
      status: "preparing", root_recording_id: first_root,
      context_recording_id: first_context,
      initiator_type: "User", initiator_id: "user-1", initiator_kind: "user"
    )
    item = batch.batch_items.new(run: second_run, position: 0, reference: "cross-root", status: "pending")
    refute item.valid?

    response = RecordingStudioAI::Response.new(response_type: "generation")
    refute response.valid?

    terminal_run = RecordingStudioAI::Run.create!(
      operation: "generation",
      status: "completed",
      root_recording_id: first_root,
      initiator_type: "User",
      initiator_id: "user-1",
      initiator_kind: "user",
      started_at: Time.current,
      completed_at: Time.current
    )
    terminal_run.resolved_provider = "openai"
    refute terminal_run.valid?

    {
      requested_by_attempt_id: invocation.errors.details[:requested_by_attempt_id],
      continued_by_attempt_id: invocation.errors.details[:continued_by_attempt_id],
      batch_run_id: item.errors.details[:run_id],
      response_base: response.errors.details[:base],
      terminal_base: terminal_run.errors.details[:base]
    }
  end
end
