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

- Dummy `/config` now matches the public API: `generate` (with `stream: true`)
  and separate batch methods. It no longer lists `stream` as a peer contract
  method.
- Dummy `/config` moves the configuration table above “Add a Provider” and
  lists every setting with required, possible values, default, and a short
  description. The initializer example now sets `batch_synchronization_job`
  and matches the `retain_responses` default.
- Dummy `/config` renders the configuration table through Flatpack column
  `html:` lambdas, so rows have real cells instead of collapsing into one
  column. Required now says where a setting is actually needed, defaults show
  real values such as attachment MIME types, and the initializer example stops
  suggesting host apps copy `providers`, `attribution_validator`, and the
  `retry_random` / `retry_sleeper` test seams.
- Dummy `/config` Create Custom Tools now includes registration-field and
  argument-field tables for `RecordingStudioAI.tools.register`.
- Dummy `/config` keeps `admin_authenticate` and AccessibleAuthorization
  guidance alongside those custom-tool tables.
- Dummy sign-in works through Cursor Cloud and Codespaces forwarded previews by
  relaxing the CSRF origin check in development when `CURSOR_AGENT` or
  `CODESPACES` is set. CSRF tokens stay required.
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
- AI Playground batch provider/profile selects refresh the batch model dropdown
  the same way Generate does (batch-capable models for the chosen profile, then
  provider).
- Deduplicated the AI Responses admin table so `Created` appears once.
- AI Playground keeps SSE streaming on a dedicated Live controller so Devise
  authentication on the show/generate page redirects to sign-in instead of
  raising `UncaughtThrowError` (`throw :warden`). Unauthenticated stream
  requests return 401.
- Extracted shared Minitest bootstrap for gem phase tests (`test/support`) covering
  SQLite persistence, configuration isolation, and recording lookup doubles.
- Admin dashboard adds Registered Providers and Registered Models widgets (top 5
  by call volume) at the end of the widget grid, plus matching table-only
  screens and section links.
- Registered Providers table includes a 30-day calls mini chart after Configured;
  clicking it opens AI Calls filtered to that provider.
- Registered Models table drops Key/Name, renames API model to Model, shows
  Temperature / Verbosity / Reasoning defaults, and uses a 30-day calls mini
  chart that opens AI Calls filtered to that provider and model.
- `.rubocop_todo.yml` records existing engine RuboCop debt from
  `copilot/v1-implement-sync-generation` (file-level excludes) so CI lint can
  pass without rewriting Orchestrator and other large files. New provider/model
  admin helpers avoid multi-line block chains, and the new widget registrations
  wrap to the 120-column limit.
- Split the Recording Studio AI admin catalog into RSA-style files under
  `lib/recording_studio_ai/admin` (shared queries, one widget/screen per file,
  section, manifest). Registration still uses `RecordingStudioAdmin.register_*`
  only. Upgrade note: require `recording_studio_ai/admin_screens` as before;
  `AdminScreens.register!` / `AdminScreens.load!` are unchanged.

### Removed

- `RecordingStudioAI.stream` and `RecordingStudioAI.stream!`.

## [0.2.9] - 2026-08-18

### Changed

- Dummy Tailwind writes Bundler gem `@source` paths before compile so Flatpack
  and Recording Studio utilities are scanned outside `vendor/bundle` /
  `/usr/local/bundle`.

### Upgrade notes

- Rebuild dummy CSS with `bundle exec rails tailwindcss:build` in `test/dummy`
  after pulling. Hosts should keep a `@source` on the installed Flatpack
  `app/components` path.

## [0.2.8] - 2026-08-18

### Changed

- Custom Tool Calls, Registered custom tools, Registered prompts, Latency by
  model, and Latency by prompt now default their date range to Last 4 weeks.
- Attempts hides the Error code column unless status is filtered to failed.
  The column also stays out of the Columns picker until then.
- Latency by model and Latency by prompt table headers explain each column in a
  tooltip. Calls on both screens is a date-range mini chart that opens matching
  AI Calls. Custom calendar dates win over a leftover Last 4 weeks preset.

### Upgrade notes

- No host configuration changes. Admin screens that used Last 30 days now open
  on Last 4 weeks.

## [0.2.7] - 2026-08-18

### Changed

- Engine admin definition modals, sparklines, data tables, warnings, and
  retained JSON now use Flatpack Modal, Chart, Table, Alert, and CodeBlock
  instead of copied markup.
- Dummy playground, tables page, and recording tree empty state use Flatpack
  Card, Table, Alert, CodeBlock, and EmptyState.

### Upgrade notes

- No host configuration changes. Admin and dummy screens keep the same jobs;
  markup now comes from Flatpack.

## [0.2.6] - 2026-08-18

### Security

- Gemini `get_batch` / `cancel_batch` allowlist `provider_batch_id` to
  `batches/<id>` so a poisoned stored name cannot call other Gemini paths with
  the host API key.
- Dummy AI playground rejects oversized uploads from claimed size *and* a
  capped read, so a lying Content-Length cannot load the file into memory.
  Gem magic-byte checks still apply after.
- Dummy AI playground shows contract/auth messages only. Unexpected exceptions
  log server-side and show a generic “try again” line (no class names).
- Engine admin supports optional `admin_authenticate` and documents that the
  engine does not authenticate by itself.
- Ships `RecordingStudioAI::AccessibleAuthorization` as the recommended
  Accessible role mapper (view / edit / admin). Install template and README
  point hosts at it instead of always-true handlers.

### Upgrade notes

- Prefer `config.authorization_handler = RecordingStudioAI::AccessibleAuthorization.method(:call)`
  once recording-studio-accessible is installed.
- Set `config.admin_authenticate` (or authenticate on `ApplicationController`)
  for engine admin routes.
- Gemini batches whose stored `provider_batch_id` is not `batches/...` will
  raise on refresh/cancel; re-submit or repair those rows.

## [0.2.5] - 2026-08-18

### Changed

- Admin weekly call/token charts and registered tool/prompt/provider/model
  sparklines aggregate with SQL `DATE(...)` grouping instead of loading every
  matching row into Ruby.
- Admin overview builds the 7-day activity window with grouped SQL queries and
  reads p95 latency via ordered offset instead of plucking every latency.
- Admin Access caches root recordings for the request so sensitive checks do not
  re-`find` each root.
- Batch sync indexes items once per apply pass instead of `find_by` per provider
  item.
- Chart widgets that need the same top-N rows for series and axis labels memoize
  that query for the request; prompt top-N name resolution uses one snapshot
  query instead of a lookup per prompt.

### Upgrade notes

- No host configuration changes. Admin chart numbers should match the previous
  totals; only query shape and request caching changed.

## [0.2.4] - 2026-08-18

### Security

- Admin run/attempt/tool/response scopes fail closed when no admin root is present
  (no more global `Run.all` / cross-tenant listings).
- Recording Studio Admin overview and AI Responses screens scope queries to the
  current admin root.
- Admin filter dropdown options (prompt keys, models, providers, tools, etc.)
  are built from the same root-scoped relations instead of global `pluck`s.
- `WarningMetrics` with `root_ids: nil` no longer scans every tenant; pass an
  explicit root id list.
- Gemini generate/stream clients send the API key only via `x-goog-api-key`
  (never as a `key=` query parameter). Streaming still uses `alt=sse` in the
  query string.
- Dummy host now wires Recording Studio AI authorization through
  RecordingStudioAccessible role mapping instead of `->(**) { true }`.
- Dummy root switcher lists only Accessible roots and uses the default
  Accessible access check (no always-allow switch).
- Dummy AI admin visible roots and Recording Studio Admin access recording
  resolvers fail closed to Accessible grants (no global-root fallback).
- Dummy AI playground refuses to run without a selected root the actor can
  edit (no first-Workspace fallback).
- Dummy Sidekiq UI is limited to actors with Accessible admin on at least one
  root, and the sidebar link is hidden otherwise.

### Upgrade notes

- Callers of `RecordingStudioAI::WarningMetrics` must pass `root_ids:` for
  meaningful results. Omitting it returns empty metrics.
- Treat the dummy initializers as the reference Accessible host pattern. Do not
  copy the old always-true authorization / all-workspaces switcher into a real
  host.

## [0.2.3] - 2026-08-18

### Changed

- Extracted `RecordingStudioAI::Orchestrator` into `Orchestration::*`
  collaborators (planner, persistence, attempt runner, plan executor, stream
  session, custom tools, response builder). Public `generate` /
  `generate(stream: true)` behavior is unchanged. Upgrade note: hosts keep
  calling `RecordingStudioAI.generate`; `Orchestrator::CancellationState` and
  `Orchestrator::CustomToolContext` remain available as aliases.

## [0.2.2] - 2026-08-18

### Changed

- Shared OpenAI and Gemini boot setup on `Providers::Base` (configuration,
  `configured?`, failed results) and install shipped providers from each class
  `provider_key`. Upgrade note: hosts keep `register_provider`,
  `models.register`, `openai_*`, and `gemini_*`. No host change is required.
  A later vendor adds `config.<provider_key>_api_key` /
  `config.<provider_key>_client`, a `Providers::*` class, and model
  registrations — not a new public API.

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
