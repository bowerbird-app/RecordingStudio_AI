# Recording Studio AI

`recording_studio_ai` is an isolated Rails engine for adding AI capabilities to
[Recording Studio](https://github.com/bowerbird-app/RecordingStudio).

This repository contains the complete V1 addon through Phase 14 acceptance hardening.
It exposes provider-independent public contracts, capability-aware profiles,
OpenAI and Gemini generation, streaming and provider batches, authorization,
six execution infrastructure tables, and a read-only FlatPack admin surface.

## Requirements

- Ruby 3.3 or newer
- Rails 8.1
- Recording Studio 4.2

The OpenAI provider uses the official `openai` Ruby SDK. Gemini uses its REST API
behind an internal client because Google does not publish an official Gemini
Ruby SDK. Both providers support injected clients.

## Installation

Add the addon and Recording Studio 4.2 to the host application's `Gemfile`:

```ruby
gem "recording_studio",
    github: "bowerbird-app/RecordingStudio",
    tag: "v4.2.0"
gem "recording_studio_ai",
    github: "bowerbird-app/RecordingStudio_AI"
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

Install and run addon migrations:

```bash
bin/rails recording_studio_ai:install:migrations
bin/rails db:migrate
```

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
indefinitely by default. To apply an explicit policy, set
`execution_history_retention_period` to a positive duration and schedule
`RecordingStudioAI::HistoryCleanupJob` or
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
There is no `/recording_studio_ai/admin` surface.

```ruby
mount RecordingStudioAI::Engine, at: "/recording_studio_ai"
recording_studio_admin_for :admin, at: "/admin", root_section: :recording_studio_ai
```

Lists (calls, attempts, tool calls, saved replies, provider batches) are Admin
screens scoped to the current Admin root. They fail closed without a root.

Saved replies open at `/recording_studio_ai/retained_responses/:id`. Listing
uses the Admin surface role (default `:view`) and the current-root match.
Decrypting still goes through `RecordingStudioAI.read_retained_response` and
requires `recording_studio_ai.view_retained_response` (Accessible `:admin`).

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
- `RecordingStudioAI.submit_batch(...)`
- `RecordingStudioAI.refresh_batch(...)`
- `RecordingStudioAI.refresh_batch_from_webhook(...)`
- `RecordingStudioAI.cancel_batch(...)`
- `RecordingStudioAI.read_retained_response(...)`
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
continuations are tracked as `continuation` attempts. Only invocation digests,
bounded summaries, safety snapshots, timing, and errors are persisted. Complete
arguments and results remain request-scoped. Non-idempotent tool execution is
never automatically repeated.

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

The dummy app preserves Recording Studio 4.2 declarations, actor wiring, root
recordings, authentication, the host sidebar shell, `UsesDefaultLayout` on gem
admin screens, and the mounted addon route. See [UPGRADING.md](UPGRADING.md)
for the 4.2 host pin.

## Cloud Agent boot

Cloud Agent Builds run `.cursor/install.sh`, then `.cursor/fetch-skills.sh`.
The install hook provisions a cold image. On a warm snapshot it skips apt,
ruby-build, db:prepare, and tailwind when Ruby, bundle, and Postgres are
already usable. Fetch-skills always runs last. `.cursor/start.sh` starts
PostgreSQL on each boot. Rebuild with Draft off to load a new pack. See
[Cursor skills in Cloud Agents](docs/cursor-skills.md).

The original template documentation remains under `docs/gem_template/` as
architectural reference only.
