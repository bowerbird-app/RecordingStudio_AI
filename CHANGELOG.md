# Changelog

All notable changes are documented here. This project follows Semantic
Versioning and Keep a Changelog.

## [Unreleased]

### Added

- `RecordingStudioAI.generate` accepts `stream: true`, optional `model:` override,
  and flat generation parameters (`temperature`, `verbosity`, `max_output_tokens`,
  `reasoning_effort`) validated against the model registry.
- AI Playground uses a single capability-driven generate form (plus a separate
  batch section) instead of Chat / Streaming / Tool Calls / Batch tabs.

### Changed

- Streaming is configured with `stream: true` on `generate` / `generate!`.
  Upgrade note: replace `RecordingStudioAI.stream(...)` with
  `RecordingStudioAI.generate(stream: true, ...)` and
  `RecordingStudioAI.stream!(...)` with `RecordingStudioAI.generate!(stream: true, ...)`.
- Batch remains on `submit_batch` / `refresh_batch*` and is not folded into
  `generate`. Playground batch demos use a secondary section on the same page.
- AI Playground generate submissions respond with a Turbo Stream, so the result
  renders in place under the "Run generate" button (above the batch section)
  without a full page reload. Batch submissions render their own result frame
  beneath the batch form.
- Deduplicated the AI Responses admin table so `Created` appears once.
- Extracted shared Minitest bootstrap for gem phase tests (`test/support`) covering
  SQLite persistence, configuration isolation, and recording lookup doubles.

### Removed

- `RecordingStudioAI.stream` and `RecordingStudioAI.stream!`.

## [0.2.0] - 2026-08-17

### Added

- Model registry (`RecordingStudioAI.models`) with declarative model definitions
  describing delivery modes, tunable parameters (temperature, verbosity,
  max output tokens, reasoning effort), native tools, and input/output
  modalities. Built-in OpenAI and Gemini models ship as registration scripts
  under `lib/recording_studio_ai/models/<provider>/<key>.rb`.
- Profiles now reference models by their provider API model string and derive
  capabilities from the model registry; explicit `capabilities:` on a profile
  entry remains supported for custom/unregistered models.
- `/config` and `/methods` guides document how to add providers, register
  models, and create profiles.
- Registered Prompts admin screen with call-volume chart, definition modal,
  and per-prompt success/error/latency metrics for the selected date range.
- Registered Prompts dashboard widget listing the top 5 most-called prompts
  in the last 30 days.
- Registered Prompts table columns for average input and output tokens.
- Registered Prompts definition modal now includes the full prompt messages.
- Attempts admin screen adds prompt/model/token/error-code filters, a Prompt
  table column, and hides AI call/sequence/kind columns by default.
- Engine phase-test schemas now apply prompt-attribution and correlation-id
  migrations so orchestrator persistence matches current run columns.
- Stacked Attempts admin chart with selectable time grouping, attempt-kind
  series, and zero-filled buckets across the complete selected period.

### Changed

- Default profiles and the install template no longer hard-code `capabilities:`
  arrays; capabilities are derived from the model registry. Upgrade note:
  existing profiles keep working (explicit `capabilities:` is still honored),
  but for models that are not registered you must either register them via
  `RecordingStudioAI.models.register(...)` or keep an explicit `capabilities:`
  entry on the profile candidate.

### Added (continued)

- Phase 2 public Ruby API contract surface for generation, streaming, batches,
	and tools registration.
- Normalized contract objects for responses, usage, cost, citations,
	attempt summaries, errors, and streaming events.
- Validation-first request contracts for generation/streaming and batch
	operations.
- Provider-SDK containment guardrails via serializable contract boundaries.
- Focused Minitest contract coverage for API validation and normalized
	response behavior prior to provider integration.
- Phase 3 migration creating six persistence infrastructure tables with
	indexes and core integrity constraints.
- Namespaced persistence models for runs, attempts, custom-tool invocations,
	batches, batch items, and retained responses.
- Terminal-state immutability protections on execution models.
- Phase 5 capability-aware profiles, provider overrides, candidate resolution,
	shared provider contracts, and content-free run/attempt orchestration.
- Phase 6 synchronous OpenAI Responses API and Gemini `generateContent`
	providers with normalized text, usage, identifiers, finish reasons, and errors.
- Official OpenAI Ruby SDK integration and contained Gemini REST transport.
- Phase 7 structured-output translation and local JSON Schema validation.
- Request-scoped image/file validation, provider translation, and safe aggregate
	attachment accounting without byte or filename persistence.
- Provider-native OpenAI and Gemini web search with dedicated authorization,
	verified citation normalization, and run/attempt search metrics.
- Phase 8 bounded retries, same-profile provider fallback, and explicit
	profile-tier fallback policies.
- Aggregate usage and compatible-currency cost accounting across successful
	and failed billable attempts, with distinct attempt kinds and run counters.
- Phase 9 versioned code-based custom-tool definitions with strict parameter
	and argument validation.
- Authorized, confirmation-aware, timeout- and result-bounded custom-tool
	execution with safe invocation summaries and non-idempotent retry protection.
- OpenAI and Gemini function-call translation with bounded continuation
	attempts and provider-neutral response summaries.
- Phase 10 OpenAI Responses and Gemini SSE streaming through normalized text,
	citation, custom-tool lifecycle, usage, completion, and error events.
- Consumer-visible retry boundaries, structured-stream validation buffering,
	cumulative Gemini chunk normalization, and request-scoped chunk containment.
- Phase 11 normalized provider batch response and item-result contracts with
	strict provider-SDK containment.
- Capability-aware batch submission, root-bound refresh, supported
	cancellation, linked run/item persistence, and idempotent usage/cost totals.
- OpenAI `/v1/responses` JSONL batches through the official SDK and verified
	Gemini `batchGenerateContent` REST batches with keyed result normalization.
- Batch custom-tool exclusion and prompt, message, attachment, and output
	non-persistence guarantees.
- Phase 12 optional encrypted, recursively sanitized, bounded, and expiring
	retention for generations, assembled streams, terminal batch items, and errors.
- Authorization-gated retained-response reading plus cleanup scope, service,
	Active Job, and host-schedulable rake task.
- Content-free lifecycle notifications and deterministic warning metrics for
	runs, attempts, retries/fallbacks, streams, tools, batches, and batch items.
- Phase 13 GET-only FlatPack administration for overview metrics, execution
	history, custom and provider-native tools, batches, and retained responses.
- Fail-closed host actor/root resolvers, root-scoped queries, separate basic,
	sensitive, and retained-response authorization, and 404 handling for hidden IDs.
- Host-primary-key-aware Recording Studio references so the six-table migration
	installs against both integer and UUID Recording Studio schemas.
- Phase 14 fail-closed authorization, strict public keyword and SDK containment
	checks, complete terminal immutability and encrypted-retention acceptance,
	unknown-preserving usage accounting, and cross-provider batch cancellation tests.
- Bounded stream idle timeout plus V1 installation, encryption-key rotation,
	response cleanup, admin authorization, provider-retention, and rollback guidance.

### Changed

- Updated dummy-host Rails to 8.1.3.1, JSON to 2.21.2, and Brakeman to 8.0.6
  to incorporate current security fixes.

### Upgrade notes

- No host changes are required for the Attempts chart. Existing admin
  authorization and visible-root scoping continue to apply.

## [0.1.0] - 2026-08-10

### Added

- `RecordingStudioAI` isolated Rails engine foundation.
- `recording_studio_ai:install` host application generator.
- Provider-neutral configuration for OpenAI and Gemini credential/client injection.
- V1 profile, retention, retry, fallback, and custom-tool-round defaults.
- Rails and Recording Studio runtime dependencies; provider SDKs are deferred.
- Dummy host validation for Recording Studio v3 integration.

[Unreleased]: https://github.com/bowerbird-app/RecordingStudio_AI/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/bowerbird-app/RecordingStudio_AI/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/bowerbird-app/RecordingStudio_AI/releases/tag/v0.1.0
