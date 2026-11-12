# Recording Studio AI

`recording_studio_ai` is an isolated Rails engine for adding AI capabilities to
[Recording Studio](https://github.com/bowerbird-app/RecordingStudio).

This engine adds AI capabilities to Recording Studio: provider-independent
public contracts, capability-aware profiles, OpenAI and Gemini generation,
streaming and provider batches, authorization, six execution infrastructure
tables, and a read-only FlatPack admin surface.

## Requirements

- Ruby 3.3 or newer
- Rails 8.1
- Recording Studio `>= 6.1.0` (development pin tag `v6.3.0`)
- Recording Studio Logs `>= 0.4.1, < 1.0` (development pin tag `v0.7.3`)
- Recording Studio Metrics `>= 0.3.0, < 1.0` (development pin tag `v0.7.2`)
- Flatpack `>= 0.1.315` (development pin tag `v0.1.341`)

The OpenAI provider uses the official `openai` Ruby SDK (`~> 0.103`, which includes
the Agents API). Gemini uses its REST API
behind an internal client because Google does not publish an official Gemini
Ruby SDK. Both providers support injected clients.

## Installation

Add the addon and Recording Studio `>= 6.1.0` to the host application's `Gemfile`:

```ruby
gem "recording_studio",
    github: "bowerbird-app/RecordingStudio",
    tag: "v6.3.0"
gem "flat_pack",
    github: "bowerbird-app/flatpack",
    tag: "v0.1.341"
gem "view_component", "4.19.0"
gem "recording_studio_ai",
    github: "bowerbird-app/RecordingStudio_AI"
gem "recording_studio_logs",
    github: "bowerbird-app/RecordingStudio_logs",
    tag: "v0.7.3"
gem "recording_studio_metrics",
    github: "bowerbird-app/RecordingStudio_metrics",
    tag: "v0.7.2"
```

`RecordingStudioAI.configuration.layout` selects the saved-reply layout. Leave it `nil` to follow `RecordingStudio.configuration.layout`, then `recording_studio/default_layout`. A layout name, `false`, or a callable that takes `controller:` is also valid. Do not include `RecordingStudio::UsesDefaultLayout` or hard-code `layout "recording_studio/default_layout"`.


AI registers site-wide run metrics. The host exposes them once:

```ruby
RecordingStudioMetrics::Api.register!(api: :operations)
```

Staff with AdminRoot `:view` (`RecordingStudioAI::Api::Access.can_view?`) can read:

- `GET /recording_studio_api/apis/operations/v1/metrics`
- `GET /recording_studio_api/apis/operations/v1/metrics/ai_runs/over_time`
- `GET /recording_studio_api/apis/operations/v1/metrics/ai_runs/by_status`
- `GET /recording_studio_api/apis/operations/v1/metrics/ai_runs/by_model`
- `GET /recording_studio_api/apis/operations/v1/metrics/ai_runs/tokens`
- `GET /recording_studio_api/apis/operations/v1/metrics/ai_runs/tokens_over_time`
- `GET /recording_studio_api/apis/operations/v1/metrics/ai_runs/avg_latency`
- `GET /recording_studio_api/apis/operations/v1/metrics/ai_runs/failed_over_time`
- `GET /recording_studio_api/apis/operations/v1/metrics/ai_runs/stuck`
- `GET /recording_studio_api/apis/operations/v1/metrics/ai_runs/stuck_over_time`
- `GET /recording_studio_api/apis/operations/v1/metrics/ai_runs/oldest_stuck_age`
- `GET /recording_studio_api/apis/operations/v1/metrics/ai_runs/tokens_by_profile`
- `GET /recording_studio_api/apis/operations/v1/metrics/ai_runs/fallback_retry_rate`
- `GET /recording_studio_api/apis/operations/v1/metrics/ai_batches/by_status`

Failure and stuck-run metrics (Recording Studio Metrics `>= 0.3.0, < 1.0`, development pin tag `v0.7.2`):

| Metric | Type / unit | Definition | `group_by` |
| --- | --- | --- | --- |
| `ai_runs.failed_over_time` | timeseries / `count` | Runs with `status: "failed"`, bucketed by `created_at` (the AI Calls list date). Takes `from` / `to` and `interval` (`day`, `week`, `month`, `year`). | `error_category` (the stored normalized category, e.g. `rate_limit`, `timeout`) |
| `ai_runs.stuck` | count / `count` | Runs with `status` `pending` or `running` whose `COALESCE(started_at, created_at)` is at least `config.stuck_run_threshold` ago. | `status`, `operation` |
| `ai_runs.stuck_over_time` | timeseries / `count` | Runs that were pending or running longer than `config.stuck_run_threshold` at each UTC day end, last 30 days. Rebuilt from `started_at` / `created_at` / `completed_at`. | none |
| `ai_runs.oldest_stuck_age` | scalar / `seconds` | Seconds since `COALESCE(started_at, created_at)` of the oldest stuck run; `value` omitted when none. | none |
| `ai_runs.tokens_by_profile` | breakdown / `tokens` | Sum of `total_tokens` per `profile_key` (blank when a run has no profile). No date window. | not supported |
| `ai_runs.fallback_retry_rate` | timeseries / `ratio` | Average of "has `retry_count > 0` or `fallback_count > 0`" over runs created in each period (0 to 1; empty bucket when no runs). Takes `from` / `to` and `interval`. | none |
| `ai_batches.by_status` | breakdown / `count` | Batches per `status`. | not supported |

Filters use the AI Calls list names: `operation`, `prompt` (`prompt_key`), `prompt_version`, `provider` (`resolved_provider`), `model` (`resolved_model`), and `status` (`pending` / `running`) on `ai_runs.stuck` and `ai_runs.oldest_stuck_age`. `ai_runs.stuck_over_time` takes the list filters except `status`. `tokens_by_profile` and `fallback_retry_rate` take the same list filters; `ai_batches.by_status` has none (there is no batch list). Groups under `min_group_size` (5) fold into `other`. There is no grouping by initiator, executor, recording, request or job ids, prompt text, or error message. The stuck metrics skip the Metrics cache so they reflect the threshold at request time. Same AdminRoot `:view` check and site scope as the other AI run metrics.

Set the stuck threshold in the initializer (default 15 minutes):

```ruby
RecordingStudioAI.configure do |config|
  config.stuck_run_threshold = 15.minutes
end
```

Then install the addon foundation:

```bash
bundle install
bin/rails generate recording_studio_ai:install
```

The generator creates `config/initializers/recording_studio_ai.rb` and mounts
the isolated engine at `/recording_studio_ai`. Use `--mount-path` to select a
different mount point:

```bash
bin/rails generate recording_studio_ai:install --mount-path=/addons/ai
```

Install Logs run tables (if the host does not already have them) and addon migrations:

```bash
bin/rails generate recording_studio_logs:migrations
bin/rails recording_studio_ai:install:migrations
bin/rails db:migrate
```

Run the migrations. `db:schema:load` from a Ruby `schema.rb` creates the tables and does not create the terminal-state guards. Rails does not dump triggers or functions into `schema.rb`.

## Configuration

Prefer Rails credentials for secrets:

```yaml
openai:
  api_key: your-openai-key
gemini:
  api_key: your-gemini-key
typesafe:
  api_key: your-typesafe-key
```

At least one OpenAI or Gemini credential or injected client is required for
generation. TypeSafe credentials are required for `decide`. The generated
initializer accepts credentials through Rails credentials or `OPENAI_API_KEY`,
`GEMINI_API_KEY`, and `TYPESAFE_API_KEY`:

```ruby
RecordingStudioAI.configure do |config|
  config.openai_api_key =
    Rails.application.credentials.dig(:openai, :api_key) ||
      ENV.fetch("OPENAI_API_KEY", nil)
  config.gemini_api_key =
    Rails.application.credentials.dig(:gemini, :api_key) ||
      ENV.fetch("GEMINI_API_KEY", nil)
  config.typesafe_api_key =
    Rails.application.credentials.dig(:typesafe, :api_key) ||
      ENV.fetch("TYPESAFE_API_KEY", nil)

  # Client objects may be injected for custom transport or testing.
  # config.openai_client = MyOpenAIClientFactory.build
  # config.gemini_client = MyGeminiClientFactory.build
  # config.typesafe_client = MyTypeSafeClientFactory.build

  config.default_profile = :medium
  # Optional microunit rates per one million tokens, keyed by provider/model.
  config.cost_catalogs = {}
  config.batch_synchronization_interval = 1.minute
  # Required: delegate every action to the host's authorization policy.
  config.authorization_handler = ->(action:, attribution:, context:) { false }
  # Provider overrides are rejected unless explicitly allowed.
  config.allowed_provider_overrides = []
  config.maximum_attachment_count = 10
  config.maximum_attachment_bytes = 20.megabytes
  config.maximum_attachment_total_bytes = 50.megabytes
  config.retain_responses = false
  config.response_retention_period = 7.days
  config.maximum_retained_response_size = 1.megabyte
  # Canonical execution history cleanup is opt-in and separate from response expiry.
  config.execution_history_retention_period = nil
  # Optional second-pass sanitizer; input has already been normalized and sanitized.
  config.response_sanitizer = nil
  config.instrumentation_enabled = true
  config.notification_namespace = "recording_studio_ai"
  config.admin_warning_thresholds = RecordingStudioAI::Configuration.new.admin_warning_thresholds
  config.admin_slow_call_threshold_ms = 10_000
  # nil lists staff runs on the current Admin root. A callable receives the
  # Admin context and returns a RecordingStudioAI::Run relation.
  config.admin_runs_scope = nil
  config.maximum_attempts = 3
  # Decision input caps. Raise maximum_decision_questions for a larger question
  # set, and raise maximum_decision_characters when those questions are long.
  config.maximum_decision_questions = 20
  config.maximum_decision_state_characters = 60_000
  config.maximum_decision_text_characters = 4_000
  config.maximum_decision_characters = 80_000
  config.maximum_retries_per_candidate = 1
  config.retry_backoff_base = 0.25 # seconds
  config.retry_backoff_max = 5.0   # seconds
  config.retry_jitter = 0.2        # 0.0..1.0
  config.maximum_provider_fallbacks = 1
  config.maximum_profile_fallbacks = 1
  # Profile-tier fallback is opt-in, for example: { high: [:medium] }.
  config.profile_fallbacks = {}
  config.maximum_custom_tool_rounds = 5
  config.custom_tool_timeout = 30
  config.maximum_custom_tool_result_size = 256.kilobytes
  # Return :approved, :rejected, :pending, or :expired. Booleans are accepted for compatibility.
  # Replace this deny-by-default handler when the host application has an approval flow.
  config.custom_tool_confirmation_handler = ->(**) { false }
  config.total_execution_timeout = 300
  config.request_timeout = 120
  config.stream_idle_timeout = 30
end
```

Profile candidate order expresses preference. Resolution selects the first
candidate that has a configured provider and supports every requested
capability. Each default tier lists generation candidates followed by the
decision candidate `{ provider: :typesafe, model: "jev-latest" }`; because Jev
declares no `:generation`, `generate` skips it and `decide` skips OpenAI and
Gemini. Model names remain in configuration rather than application logic.
Retries remain on the same candidate. Same-profile provider fallback follows
candidate order, while profile-tier fallback only follows explicit
`profile_fallbacks` mappings. For a one-off hop list that skips profiles, pass
`fallbacks: [{ provider:, model: }, ...]` on `generate` (not with `provider:` or
`model:`). For a pinned `provider:` + `model:` without call `fallbacks:`,
`config.model_fallbacks` can list the next hops (optional per-entry param
overlays allowed). Profile walks ignore `model_fallbacks`. Caller generation
overrides carry through every hop when the next model supports them;
unsupported ones are dropped rather than failing the hop.
Usage and compatible-currency cost aggregate across every reported attempt.

## Credit billing

Leave `usage_handler` nil and calls stay free. No balance check, no prices, and no boot error. `cost_catalogs` is only the real-money estimate on admin screens. It never decides what a user is charged.

Set `usage_handler` to bill. Boot then requires `usage_precheck` and a global `"*"` entry in `credit_prices`. Prices are whole credits per usage kind. `input`, `output`, `cached_input`, and `reasoning` are priced per 1,000,000 tokens. Every other kind, including `web_search` and `decision`, is priced per use unless `credit_price_per` says otherwise. Add a new kind by putting it in the price hash. The gem does not hard-code model names.

Lookup for each kind is the exact model, then that provider's `"*"`, then the global `"*"`. A registered prompt or tool can add `credit_fee:` and `credit_multiplier:` on top of that price.

Before each provider attempt the pre-check asks whether the account holds at least `minimum_credit_balance` credits. Return `true` to continue. Any other result, including a raised error, fails that attempt before the provider runs. The attempt and the run are recorded as `usage` / `usage_declined`, and no later retry or fallback starts.

After the attempt, including a retry, a fallback, or a failed attempt that still reported usage, the gem rounds the exact credits up once to a whole number. Any reported usage costs at least 1. The handler is called once with that total, a breakdown, and an idempotency key. The breakdown names the provider, model, counts, rates, extras, and prompt or tool keys. It does not include prompts, inputs, or outputs. The same attempt repeats `ai-attempt:<attempt id>`, so the host does not charge it twice.

If the handler raises, the attempt keeps the provider result and the reported usage. The run is failed as `usage` / `usage_charge_failed`, the exception propagates, and no later retry or fallback starts. Charging that same attempt again sends the same `ai-attempt:<attempt id>` key.

A batch is checked before submit and charged when refresh reports each item's usage. The item key is `ai-batch-item:<item id>`. A hosted agent turn uses the same per-kind prices and keeps `ai-hosted-agent-turn:<provider turn id>`. `perform_tool` and local tool execution are not billed.

The Stripe method names below are the host's choice. That gem is adding them separately. This gem never calls them.

```ruby
RecordingStudioAI.configure do |config|
  config.minimum_credit_balance = 1
  config.credit_prices = {
    "*" => {
      input: 100,
      output: 400,
      cached_input: 25,
      reasoning: 400,
      web_search: 5,
      decision: 2
    }
  }

  config.usage_precheck = lambda do |attribution:, minimum:|
    RecordingStudioStripe::Billing
      .for_recording(attribution.root_recording)
      .line(:pressbot)
      .credits_available?(minimum:)
  end

  config.usage_handler = lambda do |credits:, breakdown:, idempotency_key:, attribution:|
    RecordingStudioStripe::Billing
      .for_recording(attribution.root_recording)
      .line(:pressbot)
      .record_credits(credits:, breakdown:, idempotency_key:)
  end
end
```

## Operations

Response payload columns use Active Record Encryption. Before enabling
retention, configure `active_record_encryption.primary_key`,
`deterministic_key`, and `key_derivation_salt` in encrypted Rails credentials.
For rotation, add the old key through Rails' `previous` encryption schemes,
verify existing rows remain readable, and retain it until those rows expire.

Schedule `RecordingStudioAI::ResponseCleanupJob` or
`bin/rails recording_studio_ai:cleanup_responses`. Monitor cleanup failures and
rows remaining past `expires_at`. Provider-uploaded attachments can remain
subject to each provider's retention policy even though this addon does not
persist attachment bytes or filenames.

Canonical runs, attempts, tool invocations, batches, and batch items are kept
indefinitely by default. Attempts and custom tool invocations register with
RecordingStudioLogs as existing unpartitioned tables (`partition_interval: nil`).
Logs retention on those tables is `:indefinite` because attempts are referenced
by runs, responses, and tool invocations. Do not set
`RecordingStudioLogs.configure { |config| config.retention_for(...) }` on the AI
call logs. If the host needs a window, use `execution_history_retention_period`
and `RecordingStudioAI::HistoryCleanupJob`, which deletes responses and
dependents before owners. RecordingStudioLogs must not prune rows that history
still references.

Do not register aggregations or summary tables for these logs. Admin AI screens,
Metrics, and warning metrics keep reading raw attempts. Do not schedule partition
maintenance for these unpartitioned tables.

To apply an explicit history policy, set `execution_history_retention_period` to
a positive duration and schedule `RecordingStudioAI::HistoryCleanupJob` or
`bin/rails recording_studio_ai:cleanup_history`. It removes only terminal rows
older than the cutoff in one transaction and deletes dependents before owners.

Before rolling migrations back, stop execution and cleanup workers and apply
the host's execution-history retention policy. A rollback removes addon records
and retained responses, never Recording Studio recordings or events.

## Response retention and observability (Phase 12)

Response retention is disabled by default. When enabled, the engine keeps one
encrypted, recursively sanitized, size-bounded response per attempt or terminal
batch item. Generation results, assembled streams, normalized provider errors,
and batch item results are covered; prompts, stream chunks, attachments, and
complete custom-tool payloads are never retained. Raw provider snapshots remain
nil unless a provider explicitly supplies a serializable retention snapshot.

Read retained content only through the authorization-gated API:

```ruby
RecordingStudioAI.read_retained_response(
  response: retained_response,
  initiator: current_user,
  execution_source: :admin
)
```

The API derives the Recording Studio root through the response owner's run and
invokes `recording_studio_ai.view_retained_response` before decrypting content.
Schedule `RecordingStudioAI::ResponseCleanupJob` in the host application's job
scheduler, or run `bin/rails recording_studio_ai:cleanup_responses`.

Sanitized `ActiveSupport::Notifications` events use the configured namespace,
for example `recording_studio_ai.run.completed` and
`recording_studio_ai.attempt.failed`. Payloads contain identifiers, statuses,
timings, usage, cost, counts, and normalized error codes only.
`RecordingStudioAI::WarningMetrics.new(since: 24.hours.ago, root_ids: root_ids).call`
returns canonical metric values and deterministic threshold breaches for those
roots. Omitting `root_ids` fails closed (empty metrics).

## Administration

Staff use Recording Studio Admin only. Mount Admin, enable the
`recording_studio_ai` section, and grant Accessible access on that admin root.
There is no `/recording_studio_ai/admin` surface. Admin `2.7.0` and Accessible
`0.24.0` need Trashable query helpers (`require: false`); pin Metrics for
Bundler even when the host already exposes it elsewhere:

```ruby
gem "recording_studio_accessible",
    github: "bowerbird-app/RecordingStudio_accessible",
    tag: "v0.24.0"
gem "recording_studio_admin",
    github: "bowerbird-app/RecordingStudio_admin",
    tag: "v2.7.0"
gem "recording_studio_metrics",
    github: "bowerbird-app/RecordingStudio_metrics",
    tag: "v0.7.2",
    require: false
gem "recording_studio_trashable",
    github: "bowerbird-app/RecordingStudio_trashable",
    tag: "v0.12.2",
    require: false

mount RecordingStudioAI::Engine, at: "/recording_studio_ai"
recording_studio_admin_for :admin, at: "/admin", root_section: :recording_studio_ai
```

Call, attempt, tool-call, and saved-reply lists stay on the current Admin
root and fail closed without one. `config.admin_runs_scope` replaces that
relation when those lists must include runs stored on other roots. Leave it
`nil` for the current-root list. The callable receives the Admin context and
returns an `ActiveRecord::Relation` of `RecordingStudioAI::Run`. Anything
else raises a configuration error when the list is built. Do not call
`runs_scope` from inside it. Site-wide widgets keep `site_runs_scope`.

```ruby
RecordingStudioAI.configure do |config|
  config.admin_runs_scope = lambda do |context|
    next RecordingStudioAI::Run.none if context&.root_recording.nil?

    root_ids = [context.root_recording.id]
    root_ids.concat(workspace_root_ids) # host query for the other roots
    root_ids.uniq!
    RecordingStudioAI::Run.where(root_recording_id: root_ids)
  end
end
```

Provider batches is the exception. That list is site-wide, like
`ai_batches.by_status`, and can filter by model.
Expires uses Flatpack Timestamp (time ago, exact time in the tooltip).
Prompt and tool definition modals use a Flatpack card per labeled field.

Every widget on the AI section is site-wide too, including calls, tools,
latency, spend, failed runs, stuck, tokens, retry or fallback, and batches.
`/admin/screens/ai_runs_health` is the failed-run chart plus tokens-by-profile
table, with date range, group by, and AI profile filters (plus status and
stuck, so the Failed and Stuck widgets can open an already-filtered view).
Stuck and retry cards stay on the section. The failed-run headline is the
filtered window total, with percent change versus the previous period of the
same length. Provider batches chart uses the same filtered jobs as the table.

Saved replies open at `/recording_studio_ai/retained_responses/:id`. Listing
uses the Admin surface role (default `:view`) and the current-root match.
Decrypting still goes through `RecordingStudioAI.read_retained_response` and
requires `recording_studio_ai.view_retained_response` (Accessible `:admin`).
Static chrome on that page uses English Rails I18n keys under
`recording_studio.ai.retained_responses` (see `config/locales/en.yml`) via
`RecordingStudio.t`. Admin section, screen, and widget chrome under
`lib/recording_studio_ai/admin` uses `recording_studio.ai.admin.*` and
`recording_studio.ai.common.*` through `RecordingStudioAI::Copy` (prefixed
`RecordingStudio.t`). The engine registers this gem's `en.yml` with
`RecordingStudio::Translation.register_shipped_english` so missing active-locale
keys still fall back to loaded English (host overrides included), then the
merged shipped English table. Only `recording_studio.ai.*` keys use
`RecordingStudio.t`; host or other-namespace keys stay on plain `I18n.t` with
their original `default:`. A missing `_html` key with a caller `default:`
follows `RecordingStudio.t` / view `t` escaping (args escaped, template markup
kept). A plain `default:` with no interpolation is returned as a plain
(non-`html_safe`) String, so views will escape it. Hosts override keys in their
own `config/locales`. Admin table column headers stay English literals.
Requires Recording Studio `>= 6.1.0`. The saved-reply page puts its heading in `content_for :title` and `content_for :subtitle`, and its close control on `flat_pack_page_nav`.

Keep `admin_warning_thresholds`, `admin_slow_call_threshold_ms`, and
`admin_expensive_models` for widget warnings. Engine-admin resolvers
(`admin_layout`, `admin_authenticate`, `admin_actor_resolver`,
`admin_visible_roots_resolver`) are gone.

`RecordingStudioAI::AccessibleAuthorization` maps AI actions onto Accessible
roles (`:view` / `:edit` / `:admin`) for `attribution.root_recording`:

```ruby
config.authorization_handler = RecordingStudioAI::AccessibleAuthorization.method(:call)
```

Never use `->(**) { true }`.

The host authorization handler receives these independent actions:

- `recording_studio_ai.view_execution` for basic lists and details
- `recording_studio_ai.view_sensitive_execution` for snapshots, provider and
  request identifiers, errors, metadata, digests, and summaries
- `recording_studio_ai.view_retained_response` before encrypted content is read

Ordinary list screens never read encrypted columns. Screens use only the custom
tool registry and six infrastructure tables; prompts, messages, complete tool
payloads, citation URLs, and inferred internal web-search counts are absent.

## Public API contracts

Phase 2 introduced validation and normalized return contracts for:

- `RecordingStudioAI.generate(...)`
- `RecordingStudioAI.generate!(...)`
- `RecordingStudioAI.decide(...)`
- `RecordingStudioAI.decide!(...)`
- `RecordingStudioAI.perform_tool(...)`
- `RecordingStudioAI.perform_tool!(...)`
- `RecordingStudioAI.submit_batch(...)`
- `RecordingStudioAI.refresh_batch(...)`
- `RecordingStudioAI.refresh_batch_from_webhook(...)`
- `RecordingStudioAI.cancel_batch(...)`
- `RecordingStudioAI.read_retained_response(...)`
- `RecordingStudioAI::Agents.create_session(...)`
- `RecordingStudioAI::Agents.send_input(...)`
- `RecordingStudioAI::Agents.stream(...)`
- `RecordingStudioAI::Agents.submit_tool_results(...)`
- `RecordingStudioAI::Agents.cancel(...)`
- `RecordingStudioAI::Agents.delete_session(...)`
- `RecordingStudioAI::Agents.recover(...)`
- `RecordingStudioAI.tools.register(...)`
- `RecordingStudioAI.tools.fetch(...)`
- `RecordingStudioAI.tools.all`

Calls validate request contracts and return normalized contract objects.
`generate` and `generate!` resolve configured OpenAI or Gemini candidates and
dispatch through the shared provider contract. Pass `stream: true` to receive
incremental events (block or Enumerator). Optional `model:` pins a profile
candidate. Optional `fallbacks:` supplies an explicit ordered hop list and
skips configured profiles:

```ruby
RecordingStudioAI.generate(
  prompt: "Summarize this page.",
  temperature: 1,
  fallbacks: [
    { provider: :openai, model: "gpt-5-mini" },
    { provider: :gemini, model: "gemini-2.5-flash" }
  ],
  root_recording: root_recording,
  initiator: current_user
)
```

Flat generation parameters (`temperature`, `verbosity`, `max_output_tokens`,
`reasoning_effort`) are validated against the model registry. On profile or
explicit fallback hops they stay when the next model supports them and are
omitted when it does not. `RecordingStudioAI.stream` / `stream!` were removed —
use `generate(stream: true)`.

## Hosted agent sessions

`RecordingStudioAI::Agents` runs a hosted agent session through the same
credentials, run records, and usage handler as generation. The public objects
are provider-neutral. OpenAI's Agents API is the first adapter. Other providers
can implement the same methods on `Providers::Base`.

Only models registered with the `hosted_agent` operation resolve. A name that is
not in the registry raises a configuration error (`missing_model`). A registered
generation model such as `gpt-5` raises `unsupported_capability`. The default
profiles include `gpt-6-astra` for this operation. `generate` and `decide` skip
it because it does not declare those operations.

```ruby
session = RecordingStudioAI::Agents.create_session(
  instructions: "Answer in one sentence.",
  profile: :medium,
  input: "What is a session?",
  idempotency_key: "session-1",
  purpose: "agent_chat",
  root_recording: root_recording,
  initiator: current_user
)

turn = RecordingStudioAI::Agents.stream(
  session: session,
  root_recording: root_recording,
  initiator: current_user
) { |event| print event.text_delta }

RecordingStudioAI::Agents.send_input(
  session: session,
  input: "Say that again.",
  idempotency_key: "turn-2",
  root_recording: root_recording,
  initiator: current_user
)

RecordingStudioAI::Agents.cancel(session: session, root_recording: root_recording, initiator: current_user)
RecordingStudioAI::Agents.delete_session(session: session, root_recording: root_recording, initiator: current_user)
```

`stream` without a block returns an Enumerator of the same events.

Pass `tools` to register function tools on the session. Each entry is a function
definition: `type` is `"function"`, plus `name`, `description`, and `parameters`
(a JSON Schema object). `defer_loading` is optional. Other tool types are
rejected, and so is a repeated function name. Omit `tools`, or pass `tools: []`,
and the create request matches a session with no tools.

`stream` yields a `tool_calls` event and returns when the provider is waiting
on your functions. The run stays `running`. `turn.status` is `"requires_action"`
and `turn.tool_calls` is an array of `Agents::ToolCall` (`call_id`, `name`,
`arguments`, `provider_turn_id`). `arguments` is the parsed object. When the
provider payload is not a JSON object, `arguments` is nil and the call also
has `arguments_error` and `raw_arguments`. Answer that call with `error:`.
Call `submit_tool_results` after the `stream` block returns. Do not call it
from inside that block. `stream` without a block returns an Enumerator that is
not guarded: abandoning `stream(...).next` does not block a later submit on
the same thread. `submit_tool_results` reads the pending calls, then locks the
run and re-checks it. It records those `call_id`s, opens the provider event
stream, posts one `agent.session.input.tool_result` per result, and yields the
events that follow. A result is `{ call_id:, turn_id:, output: }` or
`{ call_id:, turn_id:, error: }`. `output` and `error` are Strings of at most
`Agents::Request::MAX_TOOL_RESULT_BYTES` (262144) bytes. `turn_id` has to match
the pending call. An unknown `call_id`, a duplicate `call_id`, a `call_id`
already submitted, a mismatched `turn_id`, or a turn that is finished or not
waiting raises `invalid_request` and leaves the run and its billing unchanged.
A 4xx rejection of that post, other than authentication or a rate limit, raises
the same error and leaves the run running. Call ids the provider still lists as
pending are forgotten, so those results can be submitted again. A call the
provider already accepted stays recorded. Authentication, a rate limit, a 5xx
response, a timeout, and a failure while reading the continuation keep the
provider error and leave the run running. Do this until `tool_calls` is empty:

```ruby
session = RecordingStudioAI::Agents.create_session(
  instructions: "Use the tools you were given.",
  profile: :medium,
  input: "List the latest recordings.",
  idempotency_key: "session-tools-1",
  tools: [
    {
      type: "function",
      name: "list_recordings",
      description: "List recordings the current person can read.",
      parameters: { type: "object", properties: { limit: { type: "integer" } } }
    }
  ],
  purpose: "agent_chat",
  root_recording: root_recording,
  initiator: current_user
)

turn = RecordingStudioAI::Agents.stream(
  session: session, root_recording: root_recording, initiator: current_user
) { |event| print event.text_delta }

while turn.tool_calls.any?
  results = turn.tool_calls.map do |call|
    { call_id: call.call_id, turn_id: call.provider_turn_id, output: "{\"ok\":true}" }
  end
  turn = RecordingStudioAI::Agents.submit_tool_results(
    session: session, results: results, root_recording: root_recording, initiator: current_user
  ) { |event| print event.text_delta }
end
```

`submit_tool_results` without a block returns an Enumerator of the continuation.
A dropped stream, a later `stream` on a session that is already waiting, and
`recover` all report unanswered calls on `tool_calls`, including calls whose
arguments did not parse. Saved messages are not pending calls.
`recovery.tool_calls` is empty when nothing is waiting.

A new message while the run is waiting on tool calls cancels that run at the
provider, then reads the turn and bills the usage that read reports, once.
It then starts the new message as its own turn. `cancel` does the same billing.
OpenAI reports turn usage on a best-effort basis. It can be null when unknown,
including after `agent.session.turn.cancelled`, and a later read can change
the counts. Null is not billed as zero. If the usage read fails with a
hosted-agent provider error, the run id and error class are logged and the run
stays cancelled. Any other error from that read is raised. Cancelling a finished
run does not bill it again.

Each turn is one `hosted_agent` run, attributed with the caller's `root_recording` and
authorized with `recording_studio_ai.execute`. `send_input`, `stream`,
`submit_tool_results`, `cancel`, `delete_session`, and `recover` also require a
`hosted_agent` run for that provider session on the caller's root and none on
any other root. Otherwise
they raise that same authorization error and do not call the provider. A
follow-up while that turn is still active steers it and keeps the same run. A
follow-up after the turn is terminal records a new run.

Pass `idempotency_key` on create and on every `send_input`. Follow-up submits
send that key as the provider `Idempotency-Key`. Session create has no typed
idempotency field, so the adapter sends the same header. A dropped stream fetches the saved session, turn, items, and any unanswered
function calls. It does not send the input again. A timeout raises
`Agents::Failure` and leaves the run running.

Hosted sessions are stored on the provider. OpenAI's Agents API is not Zero
Data Retention eligible. The Responses adapter still sends `store: false`;
hosted sessions do not. The OpenAI adapter uses environment `type: "none"` (no
sandbox). That environment requires the first input at create time.

`Turn#cost` is computed when read from `CostCalculator` and the configured
catalog. Token totals are stored on the run. Cost is not stored.

## Decisions (TypeSafe Jev)

`decide` is a sibling of `generate`, not a flavour of it. A decision asks a
model to classify state against caller-owned criteria and returns calibrated
probabilities. TypeSafe's Jev is the first decision-only model: it declares
`operations: [:decision]`, so it never appears as a generation candidate.

```ruby
response = RecordingStudioAI.decide(
  state: article_text, # a non-empty String
  questions: {
    mentions_target: {
      type: :noul,
      instructions: "Does this content substantially mention ACME Architects?"
    },
    coverage_type: {
      type: :choice,
      instructions: "What type of coverage is this?",
      criteria: {
        feature: "A substantial feature about the target",
        mention: "A shorter mention",
        unrelated: "Not meaningfully about the target"
      }
    },
    relevance: {
      type: :score,
      instructions: "How relevant is this content to the target?",
      criteria: ["Not relevant", "Weakly relevant", "Clearly relevant", "Primarily about the target"]
    }
  },
  profile: :medium,
  purpose: "coverage_triage",
  root_recording: root_recording,
  initiator: current_user
)

response.answers[:coverage_type].choice        # => :feature
response.answers[:coverage_type].probabilities # => { feature: 0.82, mention: 0.14, unrelated: 0.04 }
response.answers[:coverage_type].confidence    # => 0.91
response.answers[:relevance].score             # => 2.7
response.answers[:relevance].legend            # => { "0" => "Not relevant", ... }
response.answers[:mentions_target].probability # => 0.96
```

`decide!` matches `generate!`: it raises `Errors::ExecutionError` carrying the
response unless the decision succeeded.

Three question kinds, each a frozen value object under
`RecordingStudioAI::Decisions`. Hashes are parsed into them at the public
boundary, or construct them directly:

- `Choice` has 1..255 named criteria with optional descriptions. The answer is
  the caller's own criterion key plus a probability per criterion.
- `Score` has an ordered list of 2..10 labels. The answer is a numeric score on
  that scale, the legend, and a probability per string index (`"0"`, `"1"`, ...).
  A legend may be partial. Each index has to sit on the requested scale, and the
  label has to be the criterion the caller sent.
- `Noul` asks one question with optional criteria keyed by the booleans `true`
  and `false`. String keys `"true"` and `"false"` are rejected. The answer
  exposes a single `probability` and deliberately has no `confidence`.

The defaults cap state at 60,000 characters and a request at 20 questions. Each
instruction, criterion description, and score label is at most 4,000 characters,
and state plus those texts stay within 80,000 characters. Raise them together
when a call needs more room:

```ruby
config.maximum_decision_questions = 40
config.maximum_decision_characters = 200_000
```

Answers are keyed by the caller's original question key, String or Symbol, and
`:risk` alongside `"risk"` is rejected rather than merged. `response.model` is
the registry model (`jev-latest`). `response.served_model` is the versioned
identifier TypeSafe served, and the same value is stored in safe attempt metadata.

This is not `generate(schema:)`. Structured output asks a text model to emit
JSON matching a schema, and the gem parses that text. A decision never produces
text: the answers are typed, the probabilities come from the model rather than
from prose, and nothing passes through `structured_data`, schema validation,
tools, streaming, or batches. `Providers::DecisionResult` is a separate type
from `Providers::Result` for the same reason.

Decision runs persist `operation: "decision"` with the state character count
only. State, question instructions, criteria, and the provider body never reach
a column, an event payload, or a retained response. With
`retain_responses = true`, retention keeps the normalized answers as
`response_type: "decision"` and leaves `content_text` nil. TypeSafe cost stays
`nil` until a host adds a `cost_catalogs` entry for it, and
`provider_request_id` stays nil because the documented response has no request
identifier.

## Adding a provider

This gem already treats OpenAI, Gemini, and TypeSafe as adapters behind one
contract. A provider implements one or more operations — `generate`, `decide`,
streaming, and the batch methods — and declares which ones its models support.
Nothing assumes every provider implements generation: TypeSafe implements
`decide` only.

1. Subclass `RecordingStudioAI::Providers::Base` and declare `provider_key`.
2. Implement only the operations the vendor supports. The inherited defaults for
   everything else stay unimplemented, and capability filtering keeps requests
   from reaching them.
3. Add credentials the same way as today: `config.<provider_key>_api_key` and
   optional `config.<provider_key>_client`.
4. Register with `RecordingStudioAI.register_provider`, or set
   `config.discovery_enabled = true` if the class lives under
   `lib/recording_studio_ai/providers/`.
5. Register models with `RecordingStudioAI.models.register` under
   `lib/recording_studio_ai/models/<provider-key>/`, declaring
   `operations:` (`[:generation]` when omitted) and, for decision models,
   `decision_types:`.
6. Optionally add a profile candidate `{ provider: :key, model: "..." }`.

The dummy `/config` page has copy-paste examples for registration and models.

## Provider batches (Phase 11)

`submit_batch` accepts a non-empty list of uniquely referenced generation
items. Each item supplies exactly one of `prompt` or `messages` and may use a
purpose, schema, request-scoped attachments, provider-native web search, and
serializable metadata. Custom tools are rejected because they require
interactive continuation. A top-level provider override follows the same
allowlist policy as synchronous generation.

Submission resolves every item capability before creating records or calling a
provider. It creates one batch and one linked run and batch item per request.
`refresh_batch` retrieves normalized item results and idempotently updates
statuses, reported usage, and compatible-currency cost. `cancel_batch` requires
the selected candidate to declare `provider_batch_cancellation`. Batch lookup
uses the local batch ID and enforces the supplied Recording Studio root.

Provider batch webhooks (optional) wake the same refresh path. Install
[`recording_studio_webhooks`](https://github.com/bowerbird-app/RecordingStudio_webhooks),
point an OpenAI project webhook at the intake URL, then:

```ruby
config.openai_webhook_secret =
  Rails.application.credentials.dig(:openai, :webhook_secret) ||
  ENV.fetch("OPENAI_WEBHOOK_SECRET", nil)
config.webhook_batch_initiator = ->(root_recording:, **) { SystemActor.for(root_recording) }

RecordingStudioAI::Webhooks::OpenaiProvider.register!
RecordingStudioAI::Webhooks::OpenaiBatchCompletion.register!
```

`OpenaiBatchCompletion` calls `refresh_batch_from_webhook`, which never trusts
payload results — it always retrieves from the provider. Polling via
`refresh_batch_async` remains the missed-delivery fallback (and the only option
for providers without batch webhooks).

OpenAI batches upload `purpose: batch` JSONL for `/v1/responses` through the
official Ruby SDK and parse output/error files by `custom_id`. Gemini batches
use the documented `batchGenerateContent` REST API with keyed inline requests.
Provider SDK and transport objects remain internal. Prompts, messages,
attachments, generated text, and structured output are never persisted; item
results are returned only by the refresh response.

## Streaming (Phase 10)

OpenAI Responses streams and Gemini `streamGenerateContent` SSE responses emit
provider-neutral `text_delta`, `citation`, `custom_tool_requested`,
`custom_tool_started`, `custom_tool_completed`, `usage`, `completed`, and
`error` events. Streaming uses the same attribution, authorization, candidate
resolution, custom tools, usage, cost, retry, fallback, and normalized error
contracts as synchronous generation.

Retries and fallbacks are allowed only before an event has been delivered to
the consumer. Structured-output streams buffer provider events until the final
schema validates, so invalid structured content is not exposed. Provider SDK
objects and transport chunks remain request-scoped; persistence contains only
assembled metrics, counts, digests, and sanitized metadata.

## Synchronous providers (Phase 6)

OpenAI generation uses the Responses API with provider storage disabled.
Gemini generation uses `generateContent`. Both providers translate prompts,
messages, and system instructions and normalize text, provider identifiers,
finish reasons, token usage, and provider failures. Unknown cost remains `nil`.

Provider SDK and transport objects never escape the provider boundary. Runs and
attempts retain safe execution metadata, usage, counts, and digests without
persisting prompts, messages, or generated output.

## Advanced request capabilities (Phase 7)

Pass a normalized JSON Schema with `schema:` to request structured output.
OpenAI receives a strict Responses API JSON Schema format and Gemini receives
JSON response configuration. Returned JSON is parsed and validated locally;
invalid output returns a normalized `schema_validation` failure.

Attachments are request-scoped hashes containing `type` (`:image` or `:file`),
`content_type`, binary `data`, and an optional `filename`. Validation enforces
configured count, individual/combined size, MIME allowlisting, image signatures,
and filename extensions. Only count, byte total, and content types are persisted.

Use `provider_native_tools: [:web_search]` to request provider-native search.
This requires `recording_studio_ai.use_provider_native_tool` authorization.
Citations are exposed only when returned by OpenAI annotations or Gemini
grounding metadata; they are never fabricated.

## Custom tools (Phase 9)

Register versioned custom tools in application code, then reference the exact
key and version in a generation request:

```ruby
RecordingStudioAI.tools.register(
  key: :summarize_record,
  version: 1,
  name: "Summarize record",
  description: "Builds a concise summary.",
  use_when: "A record needs a summary.",
  do_not_use_when: "The source is unavailable.",
  parameters: [
    { name: :topic, type: :string, required: true, description: "Topic to summarize." }
  ],
  returns: "A serializable summary.",
  cost: :low,
  latency: :fast,
  read_only: true,
  destructive: false,
  requires_confirmation: false,
  idempotent: true,
  executor_label: "Summarizers.record",
  executor: ->(arguments, context) { Summarizers.record(arguments, context:) }
)

RecordingStudioAI.generate(
  prompt: "Summarize this record",
  custom_tools: [{ key: :summarize_record, version: 1 }],
  root_recording: root_recording,
  initiator: current_user
)
```

Definitions and arguments are validated before execution. Tool use and
confirmation have separate authorization actions; destructive tools always
require confirmation. Execution is timeout- and size-bounded, and provider
continuations are tracked as `continuation` attempts. Generation persists
invocation summaries, safety snapshots, timing, and errors. `perform_tool`
also stores the arguments and the result so a pending confirmation can resume
and a finished `request_id` can be returned again without running the tool.
Those values stay on the invocation row; metadata still redacts argument and
result keys. Non-idempotent tool execution inside `generate` is never
automatically repeated.

`perform_tool` does not call a model and does not require
`recording_studio_ai.execute`. It still requires `use_custom_tool`, and
`confirm_custom_tool` when the tool requires confirmation or is destructive.
Pass `resume: true` and `arguments: nil` with the same `request_id` to continue
a pending confirmation. `perform_tool!` raises on a real failure and returns
when the tool is waiting for confirmation.

```ruby
performance = RecordingStudioAI.perform_tool(
  tool: { key: :summarize_record, version: 1 },
  arguments: { topic: "Rails" },
  purpose: "agent_step",
  request_id: "recording-studio-agents:run-1:tool:1",
  root_recording: root_recording,
  initiator: current_user,
  initiator_kind: :agent
)

if performance.awaiting_confirmation?
  performance = RecordingStudioAI.perform_tool(
    tool: { key: :summarize_record, version: 1 },
    arguments: nil,
    resume: true,
    request_id: "recording-studio-agents:run-1:tool:1",
    root_recording: root_recording,
    initiator: current_user,
    initiator_kind: :agent
  )
end
```

## Registered prompts

Register versioned prompts in an engine or host initializer. Prompts define a
stable key, display labels, message templates, required inputs, defaults, and an
allowlist of registered custom tools:

```ruby
RecordingStudioAI.prompts.register(
  owner: "SupportApp",
  key: :customer_reply,
  version: 1,
  name: "Customer Support Reply",
  description: "Creates a concise response to a customer message.",
  inputs: %i[customer_name message],
  messages: [
    { role: :system, content: "Write a concise, helpful customer response." },
    { role: :user, content: "{{customer_name}}: {{message}}" }
  ],
  tools: [{ key: :summarize_record, version: 1 }],
  defaults: { profile: :medium, purpose: "customer_reply" }
)

RecordingStudioAI.prompt(:customer_reply, version: 1).call(
  inputs: { customer_name: customer.name, message: message.body },
  custom_tools: [{ key: :lookup_account, version: 1 }],
  root_recording: root_recording,
  initiator: current_user
)
```

Call-site `custom_tools:` are merged into the prompt's registered tools
(additive by key; same key from the caller replaces the prompt entry). The
model still decides whether to invoke any offered tool.

The method-style facade is also available for the latest registered version:

```ruby
RecordingStudioAI.prompt_methods.customer_reply(
  inputs: { customer_name: customer.name, message: message.body },
  root_recording: root_recording,
  initiator: current_user
)
```

Hosts and extension gems can replace only their own reloadable declarations:

```ruby
Rails.application.reloader.to_prepare do
  RecordingStudioAI.prompts.replace_owner("SupportApp") do |registry|
    SupportPrompts.register(registry)
  end
end
```

Prompt inputs use strict `{{snake_case}}` placeholders. Rendered templates and
values are never persisted. Runs snapshot the prompt key, version, and name,
allowing AI Calls reporting to filter and group prompt usage. Custom tool
invocations inherit prompt attribution through their run.

Hosts can replace an existing registration with the same key and version using
`override: true` on models, prompts, and tools. For prompts, the existing entry
must allow it: set `overridable: true` when registering (the default), or lock
the entry with `overridable: false` so hosts cannot replace it.

Gem registers an open prompt:

```ruby
# In a gem initializer
RecordingStudioAI.prompts.register(
  owner: "SupportGem",
  key: :customer_reply,
  version: 1,
  name: "Customer Support Reply",
  description: "Creates a concise response to a customer message.",
  overridable: true, # default; omit if you want the same behavior
  inputs: %i[customer_name message],
  messages: [
    { role: :system, content: "Write a concise, helpful customer response." },
    { role: :user, content: "{{customer_name}}: {{message}}" }
  ],
  defaults: { profile: :medium, purpose: "customer_reply" }
)
```

Host overrides that same key and version in an app initializer that loads after
the gem:

```ruby
# config/initializers/recording_studio_ai_prompts.rb
RecordingStudioAI.prompts.register(
  owner: "Host",
  key: :customer_reply,
  version: 1,
  name: "Host Customer Reply",
  description: "Our in-house tone for customer replies.",
  override: true, # required to replace the gem entry
  overridable: true, # whether a later register may replace this host entry
  inputs: %i[customer_name message],
  messages: [
    { role: :system, content: "Be brief, warm, and specific. No filler." },
    { role: :user, content: "{{customer_name}}: {{message}}" }
  ],
  defaults: { profile: :medium, purpose: "customer_reply" }
)
```

Calls keep using the same key — no call-site change:

```ruby
RecordingStudioAI.prompt(:customer_reply).call(
  inputs: { customer_name: customer.name, message: message.body },
  root_recording: root_recording,
  initiator: current_user
)
```

Lock a prompt so hosts cannot replace it:

```ruby
RecordingStudioAI.prompts.register(
  owner: "SupportGem",
  key: :billing_escalation,
  version: 1,
  name: "Billing Escalation",
  description: "Fixed wording for billing escalations.",
  overridable: false,
  inputs: %i[account_id],
  messages: [
    { role: :system, content: "Escalate billing issues with the required disclaimer." },
    { role: :user, content: "Account {{account_id}}" }
  ]
)
# Later register(..., override: true) for the same key/version raises.
```

`replace_owner` still replaces only that owner's own registrations on reload and
does not bypass another owner's `overridable: false` entry.

Models and tools still use `override: true` without an `overridable:` policy:

```ruby
RecordingStudioAI.models.register(
  provider: :openai,
  key: "gpt-5",
  model: "gpt-5",
  override: true,
  # ...
)

RecordingStudioAI.tools.register(
  key: :summarize_record,
  version: 1,
  override: true,
  # ...
)
```

## Resolution and execution (Phase 5)

Candidates declare a provider, model, and capabilities. Supported capability
keys are `generation`, `decision`, `decision_choice`, `decision_score`,
`decision_noul`, `streaming`, `structured_output`, `image_input`, `file_input`,
`provider_native_web_search`, `custom_tools`, `provider_batch`, and
`provider_batch_cancellation`. Operation capabilities come from a model
definition's `operations:` and `decision_types:`; the rest are derived from its
delivery flags, tools, and modalities.

Resolution never removes requirements. Unsupported requests and disabled
provider overrides fail before a run, attempt, or provider call is created.
Successful and failed provider calls persist runs and actual attempts using safe
metadata, counts, and digests, without prompts, messages, or generated content.

## Persistence (Phase 3)

Phase 3 adds exactly six infrastructure tables:

- `recording_studio_ai_runs`
- `recording_studio_ai_attempts`
- `recording_studio_ai_custom_tool_invocations`
- `recording_studio_ai_batches`
- `recording_studio_ai_batch_items`
- `recording_studio_ai_responses`

These are execution infrastructure tables only. They are not Recording Studio
recordables and do not persist prompts, messages, attachment bytes, or full
custom-tool payloads.

## Development

Run the focused gem suite:

```bash
bundle exec rake test
```

Validate the addon inside the dummy Recording Studio host:

```bash
bundle exec rake test:dummy
cd test/dummy
bin/dev
```

The dummy app preserves Recording Studio `>= 6.1.0` declarations, actor wiring,
root recordings, authentication, the host sidebar shell, `config.layout` on
the saved-reply controller, and the mounted addon route. See [UPGRADING.md](UPGRADING.md)
for the `>= 6.1.0` host pin.

Dummy credentials (`test/dummy/config/credentials.yml.enc`) are encrypted with
the shared RecordingStudio_* development master key. Set `RAILS_MASTER_KEY` or
put that key in `test/dummy/config/master.key` (gitignored). Keep the encrypted
file; do not generate a per-repo dummy key.

## Cloud Agent boot

Cloud Agent Builds run `.cursor/install.sh`, then `.cursor/fetch-skills.sh`.
The install hook provisions a cold image. On a warm snapshot it skips apt,
ruby-build, db:prepare, and tailwind when Ruby, bundle, and Postgres are
already usable. If `RAILS_MASTER_KEY` is set, `install.sh` writes gitignored
`test/dummy/config/master.key` so dummy credentials decrypt. Fetch-skills
always runs last. `.cursor/start.sh` starts PostgreSQL on each boot. Rebuild
with Draft off to load a new pack. See
[Cursor skills in Cloud Agents](docs/cursor-skills.md).

The dummy `/config` page shows a copy-paste third-party provider adapter from
`RecordingStudioAI::Providers::StarterExample`.
