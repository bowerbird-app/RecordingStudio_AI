# Changelog

All notable changes are documented here. This project follows Semantic
Versioning and Keep a Changelog.

## [Unreleased]

### Changed

- `RecordingStudioAI.prompt(...).call` / `stream` merges call-site
  `custom_tools:` into the prompt's registered tools (additive by key). Prompt
  tools come first; a caller entry with the same key replaces that prompt tool
  (including a different version). Omitting `custom_tools:` keeps the prompt
  list. Listing a tool only offers it to the model — the model still decides
  whether to call it.
  **Upgrade:** callers that relied on
  `registered prompt custom tools cannot be overridden` will now succeed and
  receive the merged tool list.

### Added

- `RecordingStudioAI.prompts.register(..., overridable: true|false)` declares
  whether another registration may replace the same key and version with
  `override: true`. Default is `true` (current behavior). Set `overridable: false`
  to lock a gem prompt. `replace_owner` still only swaps that owner's own
  registrations.
- Webhook preparation for provider batch completion via
  `recording_studio_webhooks` (optional host dependency, not a gemspec require):
  `RecordingStudioAI.refresh_batch_from_webhook` looks up a batch by
  `provider_batch_id` within `root_recording` and runs the existing
  `refresh_batch` path with `execution_source: :webhook`. Optional OpenAI
  recipes `RecordingStudioAI::Webhooks::OpenaiProvider.register!` and
  `OpenaiBatchCompletion.register!` register intake verify + `batch.*` wake
  actions when the webhooks gem is installed. Keep
  `BatchSynchronizationJob` as the poll fallback. Set
  `config.openai_webhook_secret` and `config.webhook_batch_initiator` (or pass
  `initiator:`) before using the recipes.
- `RecordingStudioAI::Models::ParameterValidation.adapt_for_model` soft-applies
  caller generation overrides to a candidate: keeps supported values (clamped to
  that model's range), omits unsupported parameters and disallowed enum values,
  and does not raise the way `normalize!` does for a pinned model. Profile hops
  in `AttemptRunner` use this so a caller override (for example `temperature: 1`)
  travels to the next candidate when that model supports it, instead of failing
  the hop or resetting to the fallback model's default.
- `RecordingStudioAI.generate(..., fallbacks: [...])` takes an explicit ordered
  candidate list (`{ provider:, model: }` plus optional generation params) and
  skips configured profiles, `profile_fallbacks`, and `model_fallbacks`. Do not
  combine `fallbacks:` with `provider:` or `model:`. Caller generation overrides
  still adapt per hop. `profile:` remains for run attribution only.
- `config.model_fallbacks` maps a pinned primary `[provider, model]` (or
  `"provider/model"`) to an ordered hop list. Used only when `provider:` and
  `model:` are both set and `fallbacks:` is not. Profile walks ignore it. Entries
  may include hop-only param overlays (for example `temperature:`); caller
  overrides still win, then entry overlays fill gaps, then the model default.
- `RecordingStudioAI.prompts.register(..., override: true)` replaces an existing
  prompt registration with the same key and version, matching model registration.
- `RecordingStudioAI.tools.register(..., override: true)` replaces an existing
  tool registration with the same key and version, matching models and prompts.
- Model parameter specs require `type:` (`:number`, `:integer`, or `:string`).

### Changed

- Model parameter registration drops `supported:`. Listing a parameter means it
  is supported; omit it when the model cannot take it. Upgrade note: remove
  `supported: true/false` from `RecordingStudioAI.models.register` parameter
  hashes, and add `type:` (for example `temperature: { type: :number, ... }`,
  `verbosity: { type: :string, ... }`, `max_output_tokens: { type: :integer, ... }`).
- Registered prompt and custom tool name cells open their definition modal from
  a Flatpack link instead of a ghost button.
- Registered Prompts definition modal shows System Prompt and User Prompt code
  blocks without a wrapping card. The modal drops the outer "Prompt" label,
  renames Key to Prompt Key, and shows Registered by from the prompt `owner`
  (gem or host label such as `RecordingStudioAI`, `Host`, or
  `RecordingStudioAdmin`). Upgrade note: set `owner:` to a PascalCase gem or
  host label when registering prompts; snake_case owners are no longer valid.

- Prompt registration drops `namespace` and `short_name`. Prompts are keyed by
  `key` and `version` only; `name` remains the display label. Upgrade note:
  remove `namespace` and `short_name` from `RecordingStudioAI.prompts.register`
  calls, replace `RecordingStudioAI.prompt(:namespace, :key)` with
  `RecordingStudioAI.prompt(:key)`, and replace
  `RecordingStudioAI.prompt_methods.namespace.key` with
  `RecordingStudioAI.prompt_methods.key`. Run the migration that removes
  `prompt_namespace` and `prompt_short_name_snapshot` from
  `recording_studio_ai_runs`.

- `RecordingStudioAI.generate` accepts `stream: true`, optional `model:` override,
  optional `fallbacks: [{ provider:, model: }, ...]`, and flat generation
  parameters (`temperature`, `verbosity`, `max_output_tokens`, `reasoning_effort`)
  validated against the model registry. Upgrade note: on profile hops or explicit
  `fallbacks:`, caller overrides travel to the next candidate when that model
  supports them (clamped to its range) and are omitted when it does not. A hop
  no longer fails the run for an unsupported parameter such as `verbosity`.
  Parameters you did not set stay unset so each model can use its own default.
  Do not combine `fallbacks:` with `provider:` or `model:`; `profile:` still
  records run attribution when using explicit fallbacks.
- AI Playground uses a single capability-driven generate form (plus a separate
  batch section) instead of Chat / Streaming / Tool Calls / Batch tabs.

### Changed

- AI Calls chart is a line of call volume over time again, with Group by
  hour/day/week/month/year. The Calls by provider/model screen still has the
  horizontal bar by model or provider.
- Retained response detail uses a Flatpack table for retention metadata.
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
- Dummy `/config` splits registry override docs into dedicated sections:
  Override a Model (under Add a Model), Override a Tool (after Create Custom
  Tools), Register a Prompt (with field table), and Override a Prompt. The
  combined Registry overrides block is gone.
- Dummy `/methods` shows generate call sites for an inline prompt, a registered
  prompt (`prompt(...).call` / `stream`), and registered custom tools. Register
  and override examples stay on `/config`. Also documents hop params on
  `fallbacks:` and `refresh_batch_from_webhook`.
- Test suite requires `minitest-mock` so `Object#stub` works under Minitest 6
  (extracted from core minitest). The root `test_helper` soft-loads it so the
  dummy app bundle can still boot `recording_studio_v3_test`.
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

### Upgrade notes

- The AI Calls admin chart is a time series again. Use Calls by provider/model
  for the horizontal bar of volume by model or provider.

## [0.2.11] - 2026-08-19

### Changed

- Dummy host sidebar header shows `RecordingStudioAI::VERSION` instead of
  Flatpack’s gem version.
- Attempts table shows the tool names used on a try, when that try asked
  for tools.
- Registered prompts chart summary counts calls in the selected date range,
  not the number of prompt definitions, so the period change is no longer
  stuck at 0%.
- Latency by model and Latency by prompt chart summaries use overall P90
  in the selected date range, not the number of grouped rows, so Last 4
  weeks is no longer stuck at 0%. Lower P90 is treated as an improvement.
- Registered providers table drops the Starter file column. The Models
  count opens Registered models filtered to that provider.
- Registered prompts hides Namespace and Key by default and adds a column
  picker so those fields can be turned back on.
- Attempts chart and kind badges say "1st attempt" and "After tools"
  instead of Primary and Continuation.
- Estimated spend is now Estimated token usage. The screen chart is a
  horizontal bar of every model in the selected range, and the headline
  number is token total rather than call count. The dashboard widget
  sits after Calls by provider/model.
- AI Calls chart is a horizontal bar of call volume by model in the
  selected date range, matching the Calls by provider/model widget.
- Calls by provider/model is its own admin screen with a horizontal bar
  chart (models by default, or providers via Group by). The Group by
  control defaults to Model. The dashboard widget opens that screen.
  Prompt, status, and model filters sit in the modal. Provider and model
  filters only list registered providers and models.
- Dashboard P90 widgets are renamed to AI Prompt P90 latency and AI
  Response P90 latency, with the prompt widget shown first.
- AI Responses table shows the run as `#123`, adds Prompt name, and drops
  Type, Finish, and Bytes. Date range, provider, and model stay inline.
- Retained response detail shows retention metadata in a simple table
  instead of a card.

### Upgrade notes

- Hosts that copied the dummy Flatpack sidebar header still show Flatpack’s
  version until they override that badge the same way.
- The providers admin table no longer ships a Starter file modal. Use the
  dummy `/config` starter, or `RecordingStudioAI::Providers::StarterExample`,
  if you still need a copy-paste adapter.

## [0.2.10] - 2026-08-18

### Changed

- The retained-response admin viewer copies Recording Studio Admin access when
  that gem is installed: authenticate, then
  `RecordingStudioAdmin::Authorization.authorize!` against the access recording
  and `required_access_role` (default `:view`), including the current-root
  match. Lookups stay inside that admin root. The public
  `read_retained_response` API still requires `view_retained_response`.
  The Admin access helper is autoloaded from `app/controllers` with the
  retained-response controller so a development reload still finds it.

### Upgrade notes

- Operators who can open AI Responses can open the retained body. Hosts that
  previously required Accessible `:admin` for that drill-down should raise
  Recording Studio Admin `required_access_role` or tighten grants on the access
  recording.

## [0.2.9] - 2026-08-18

### Added

- Registered providers screen includes a Starter file modal with a copy-paste
  `my_provider.rb` adapter and initializer env wiring
  (`config.my_provider_api_key = ENV.fetch(...)`). Dummy `/config` shows the
  same starter next to the existing registration examples.

### Changed

- Dummy Tailwind writes Bundler gem `@source` paths before compile so Flatpack
  and Recording Studio utilities are scanned outside `vendor/bundle` /
  `/usr/local/bundle`.
- Dummy AI Playground generate form picks a registered prompt from a dropdown
  and shows that prompt in a disabled textarea. Prompts that declare inputs
  (such as Text Summary and Text Analysis) show a text field for custom input.
  Generate sends the registered prompt, filled-in inputs, and its tools. The
  custom-tool checkbox and dropdown stay available so you can add a playground
  tool on any supported model.
- Gemini generate requests that mix web search with custom tools send
  `toolConfig.includeServerSideToolInvocations`. If Gemini still refuses the
  mix, the error says to turn one of them off.
- Generation response JSON serializes `run` as `{ id: }` instead of the Active
  Record inspect string.
- AI Calls, Custom Tool Calls, Attempts, Estimated spend, Registered custom
  tools, Registered prompts, Registered providers, and Registered models table
  headers explain each column in everyday language.

### Upgrade notes

- Rebuild dummy CSS with `bundle exec rails tailwindcss:build` in `test/dummy`
  after pulling. Hosts should keep a `@source` on the installed Flatpack
  `app/components` path.
- `response.to_h[:run]` is now `{ id: run.id }` when the run has an id. Update
  any host that parsed the old inspect string.

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
