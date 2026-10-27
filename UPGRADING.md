# Upgrading RecordingStudioAI

## Upgrading to 0.19.0

Adopts Recording Studio 6.1 layouts and Flatpack 0.1.319. No migration.

### What changed

- `recording_studio` is `>= 6.1.0`. Development pins tag `v6.1.0`.
- `flat_pack` is `>= 0.1.315`. Development pins commit `1fcbafe94f8eb118f0a22182f63f5110fcc97a56` (`FlatPack::VERSION` `0.1.319`). The newest git tag is `v0.1.315`.
- `view_component` stays in `>= 4.14, < 5`. Development locks `4.19.0`.
- `RecordingStudioAI.configuration.layout` is `nil`, `false`, a layout name, or a callable that takes `controller:`. `nil` uses `RecordingStudio.configuration.layout`, then `recording_studio/default_layout`.
- `RecordingStudioAI::RetainedResponsesController` calls `recording_studio_layout`. `RecordingStudio::UsesDefaultLayout` is removed.
- The saved-reply heading is `content_for :title` and `content_for :subtitle`. Close is `flat_pack_page_nav`. Access avatars stay in `recording_studio_page_nav_right`.
- Cards use `border:` and `shadow:` instead of `style:`.

### Upgrade steps

1. Install RecordingStudioAI `0.19.0`.
2. Pin Recording Studio to GitHub tag `v6.1.0`.
3. Pin Flatpack to `>= 0.1.315`. This repo uses commit `1fcbafe94f8eb118f0a22182f63f5110fcc97a56`.
4. Lock `view_component` at `4.19.0` unless the host already allows another `4.x` release at `>= 4.14`.
5. Delete `include RecordingStudio::UsesDefaultLayout` and any `layout "recording_studio/default_layout"`. Set `config.layout` only when the host must override the core layout.
6. On pages that use `recording_studio/default_layout`, set `content_for :title` and remove the duplicate page-level `FlatPack::PageTitle`. Put back and close on `flat_pack_page_nav`. Put page actions on `register_page_nav` or `recording_studio_page_nav_right`.
7. Load `flat_pack/variables`, `flat_pack/application`, and `flat_pack/rich_text` before Tailwind.

Sibling gems that still require Recording Studio below 5 can be widened in the host Gemfile with `test/support/widen_recording_studio_requirement.rb`. Do not fork those gems for the constraint alone.

## Upgrading to 0.18.1

Widens Logs and Metrics runtime ceilings to `< 1.0`. No code change. No migration.

### What changed

- `recording_studio_logs` is `>= 0.4.1, < 1.0` (CI tested with 0.5.0).
- `recording_studio_metrics` is `>= 0.3.0, < 1.0` (CI tested with 0.5.0).

### Upgrade steps

Install RecordingStudioAI `0.18.1`. No migration is required.

## Upgrading to 0.18.0

Adopts RecordingStudioLogs registration for the AI call log. This release
includes a migration. There are no summary tables.

### What changed

- The existing `recording_studio_ai_attempts` and
  `recording_studio_ai_custom_tool_invocations` tables stay in place. They are
  not copied, switched, or partitioned. Primary keys stay integer `id`.
- `root_recording_id` is added and backfilled from `recording_studio_ai_runs`.
  New rows copy the run's root on create.
- Both tables register with RecordingStudioLogs (`partition_interval: nil`,
  `retention: :indefinite`, no `aggregate` calls). Admin AI screens, Metrics,
  and warning metrics keep reading raw attempts.
- Logs retention on these tables is indefinite. Attempts are tied to run history
  (foreign keys and integrity triggers). RecordingStudioLogs must not prune rows
  that runs or responses still reference. Hosts that want a window keep using
  `execution_history_retention_period` and `HistoryCleanupJob`.
- Aggregatable columns exclude prompts, outputs, actor, IP, and error text.

### Upgrade steps

1. Bump the host gem to `0.18.0`.
2. Pin `recording_studio_logs` to GitHub tag `v0.5.0` (allowed range
   `>= 0.4.1, < 0.6`).
3. If Logs run tables are missing: `bin/rails generate recording_studio_logs:migrations`.
4. `bin/rails recording_studio_ai:install:migrations` then `bin/rails db:migrate`.

Do not schedule partition maintenance for these unpartitioned tables.

## Upgrading to 0.17.1

Admin AI section chart tick labels. No migration.

### What changed

- Failed runs and Stuck runs charts hide x-axis labels and default to the last 30 days.
- Retry or fallback rate y-axis labels round to two decimal places.

### Upgrade steps

Install RecordingStudioAI `0.17.1`. No migration is required.

## Upgrading to 0.17.0

Admin AI run health and provider batches screens. No migration.

### What changed

- `/admin/screens/ai_runs_health` filters by date range, group by, and AI profile. Failed and Stuck widgets open that screen with the matching status or stuck filter and the widget date range.
- The failed-run headline compares the previous period of the same length. Fewer failures are green, more are red, and no change or no prior data is an em dash.
- Provider batches chart totals come from the filtered table relation, so date, status, provider, and model match the list.

### Upgrade steps

Install RecordingStudioAI `0.17.0`. No migration is required. Keep Metrics at `>= 0.3.0, < 0.6`.

## Upgrading to 0.16.1

Widens Metrics so the gem can run on RecordingStudio_metrics 0.5.0. No migration.

### What changed

- Runtime dependency `recording_studio_metrics` is `>= 0.3.0, < 0.6` (tag `v0.5.0`).
- Admin charts still hand `{ x:, y: }` points to Flatpack. Metrics 0.5.0 `Admin.chart_series` already returns that shape; this gem still maps execute rows (`date` / `value`) into those points.

### Upgrade steps

Install RecordingStudioAI `0.16.1` and pin Metrics `>= 0.3.0, < 0.6` (tag `v0.5.0`). No migration is required.

## Upgrading to 0.16.0

Adds Admin screens and dashboard widgets for the existing AI metrics. No migration.

### What changed

- `/admin/screens/ai_runs_health` shows failed runs by error category over the last 30 days, plus tokens by profile. The stuck and retry cards stay on the AI section, not inside the health screen.
- The Stuck runs card keeps the live count and draws a 30-day line from `ai_runs.stuck_over_time`.
- Failed-run and retry-or-fallback headlines are the window total or rate, not today's empty bucket.
- Admin AI section widgets are site-wide, same as the metric cards.
- Provider batches shows `ai_batches.by_status` as a chart above the list. The list is the same site-wide set as that metric, with a model filter. Expires is a Flatpack timestamp.
- The AI Admin section dashboard adds five widgets that link to those screens. Values come from `RecordingStudioMetrics.execute`.

### Upgrade steps

Install RecordingStudioAI `0.16.0`. No migration is required. Keep mounting Admin with the `recording_studio_ai` section and grant Accessible `:view` as before.

## Upgrading to 0.15.1

Closes a cross-root hole in hosted agent sessions. No migration.

### What changed

`send_input`, `stream`, `cancel`, `delete_session`, and `recover` now require a `hosted_agent` run for that provider session on the caller's root, and no `hosted_agent` run for it on any other root. A missing run and a run on another root both raise the existing authorization error. The provider is not called.

### Upgrade steps

Install RecordingStudioAI `0.15.1`. No migration is required.

## Upgrading to 0.15.0

Adds provider-neutral hosted agent sessions. This release includes a migration.

### What changed

- `RecordingStudioAI::Agents` creates a session, sends follow-up input, streams events, cancels the active turn, deletes the session, and recovers after a dropped stream.
- Runs gain nullable `provider_session_id` and `provider_turn_id`. `operation` may be `hosted_agent`.
- The `openai` dependency is `~> 0.103` because the Agents API is not in 0.80.
- Default profiles include `gpt-6-astra` for hosted sessions. Generation and decision resolution skip it.
- Each turn with reported tokens spends `total_tokens` under idempotency key `ai-hosted-agent-turn:<provider turn id>`.

### Upgrade steps

Install RecordingStudioAI `0.15.0`, bundle `openai` `~> 0.103`, and run migrations. Hosted sessions are stored on OpenAI and are not Zero Data Retention eligible. The Responses path still sends `store: false`. The adapter uses environment `type: "none"` (no sandbox) and requires the first input when the session is created.

## Upgrading to 0.14.0

Adds three operations metrics and pins Metrics to the 0.3 line. No migration.

### What changed

- New metrics: `ai_runs.tokens_by_profile`, `ai_runs.fallback_retry_rate`, `ai_batches.by_status`.
- Runtime dependency `recording_studio_metrics` is `>= 0.3.0, < 0.4` (tag `v0.3.1`).
- Definitions still register from `RecordingStudioAI::Metrics.register!` with `api_authorize`. The host still calls `RecordingStudioMetrics::Api.register!(api: :operations)` once. MCP 0.17 builds one tool per metric from Metrics discovery.

### Upgrade steps

Install RecordingStudioAI `0.14.0` and pin Metrics `>= 0.3.0, < 0.4`. No migration is required. Keep the host `Api.register!` call. Staff with AdminRoot `:view` can read the new metrics on the operations API.

## Upgrading to 0.13.0

Translation-only upgrade. English hosts keep the same rendered text.
Missing-locale lookups for gem-shipped `recording_studio.ai.*` keys fall back
to loaded English (host overrides included) instead of showing
“Translation missing”.

### What changed

- Requires RecordingStudio `~> 4.7`.
- The engine registers `config/locales/en.yml` with
  `RecordingStudio::Translation.register_shipped_english` at boot (before
  RecordingStudio loads the merged shipped-English table).
- Saved-reply and other gem chrome use `RecordingStudio.t` (or
  `RecordingStudioAI::Copy.t` for relative `recording_studio.ai.*` keys). There
  is no gem-local `RecordingStudioAI::Translation` / `RecordingStudioAI.t`.
- Only this gem's `recording_studio.ai.*` keys go through `RecordingStudio.t`;
  host or other-namespace keys stay on plain `I18n.t` with main's `default:`.
- Fallback order for gem keys missing in the active locale (from core):
  1. loaded `:en` (host English overrides included)
  2. caller's `default:`
  3. merged shipped English table (base `en.yml` plus registered addon paths)
- Saved-reply view and Admin `Copy.t` call sites no longer pass hand-copied
  English `default:` values.
- A missing `_html` key with a caller `default:` now follows
  `RecordingStudio.t` / view `t` escaping (args escaped, template markup kept)
  instead of main's whole-template escaping on hand-copied defaults. A plain
  `default:` with no interpolation is returned as a plain (non-`html_safe`)
  String, so views will escape it. No in-gem call site does this.

### Upgrade steps

Install RecordingStudioAI `0.13.0` with RecordingStudio `~> 4.7`. No migration
is required. English hosts need no change. Prefer `RecordingStudio.t` (full key)
or `Copy.t` (relative key) for new gem copy. Partial pluralization data in a
non-English locale still raises `I18n::InvalidPluralizationData`.

## Upgrading to 0.11.0

Mostly a translation-shape upgrade. English for `count` 1 now says `call`
instead of main's always-plural `calls`.

### What changed

- `recording_studio.ai.admin.alerts.high_usage` is an I18n plural key (`one` /
  `other`). Call sites pass numeric `count:` for form selection and
  `formatted_count` for the delimited number (same as main's
  `number_with_delimiter`). English `one` uses `call`; `other` uses `calls`.

### Upgrade steps

No migration is required. Host overrides should use `one` / `other` with
`%{formatted_count}` to keep the thousands delimiter. A main-style `%{count}`
override interpolates the raw Integer (`1000`, not `1,000`).

## Upgrading to 0.10.0

This is a translation-only upgrade for English hosts. Rendered English interface
text matches main (no new UI, filters, dialogs, or reachability changes).

### What changed

- Admin DSL chrome under `lib/recording_studio_ai/admin` (section, screens,
  widgets, charts, summary labels, resource actions, attempt-kind labels, empty
  states, and related cell/aria/modal copy that the DSL evaluates at render
  time) uses Rails I18n via `RecordingStudioAI::Copy`.
- Keys live under `recording_studio.ai.admin.*` and
  `recording_studio.ai.common.*` in the gem's `config/locales/en.yml`.
- `ATTEMPT_KIND_LABELS` remains the public English constant map. Display strings
  resolve at call time through `attempt_kind_label`.
- Saved-reply view lookups pass an English `default:` so a host locale without
  fallback never shows “translation missing”.

Left untranslated on purpose:

- Admin table column headers, header tooltips, and filter titles (Admin DSL
  stores them as strings at class load)
- Model integrity `errors.add` sites (ActiveModel 8.1 ignores `message:` for
  String types; left byte-identical to main):
  - `CustomToolInvocation` — `"must belong to the same run"`
  - `BatchItem` — `"must belong to the batch root"` /
    `"must use the batch context"`
  - `Response` — `"exactly one of attempt_id or batch_item_id must be present"`
  - `TerminalImmutability` — `"Cannot modify terminal fields after status is terminal: …"`
- Developer `ArgumentError`s, logs, generator CLI text, AI prompt content sent
  to models, icon/style tokens, stored/user data, and dummy-app chrome

### Upgrade steps

No migration is required. English hosts need no change. To override or add
another language, set the keys above in the host's `config/locales`. Quote
`"yes"` / `"no"` keys in host YAML (YAML 1.1 otherwise treats them as
booleans). Profile Kind filter params stay the English tokens `Generative` /
`Decision`; translate only display via `common.generative` /
`common.decision`.

## Upgrading to 0.8.0

This is a non-breaking upgrade. Rendered English interface text is unchanged.

### What changed

- Static copy on the gem's saved-reply page
  (`app/views/recording_studio_ai/retained_responses/show.html.erb`) uses Rails
  I18n keys under `recording_studio.ai.retained_responses`.
- The gem ships English only in `config/locales/en.yml` (Rails engines load
  that path by default). There is no dependency on
  `recording_studio_internationalization`.

Keys added:

| Key | English |
| --- | --- |
| `recording_studio.ai.retained_responses.close` | Close |
| `recording_studio.ai.retained_responses.page_title` | Saved reply |
| `recording_studio.ai.retained_responses.page_subtitle` | What the model sent back. |
| `recording_studio.ai.retained_responses.about_title` | About this reply |
| `recording_studio.ai.retained_responses.type` | Type |
| `recording_studio.ai.retained_responses.status` | Status |
| `recording_studio.ai.retained_responses.cut_short` | Cut short |
| `recording_studio.ai.retained_responses.size` | Size |
| `recording_studio.ai.retained_responses.expires` | Expires |
| `recording_studio.ai.retained_responses.content_type` | Content type |
| `recording_studio.ai.retained_responses.open_call` | Open this call |
| `recording_studio.ai.retained_responses.complete` | Complete |
| `recording_studio.ai.retained_responses.incomplete` | Incomplete |
| `recording_studio.ai.retained_responses.truncated` | Truncated |
| `recording_studio.ai.retained_responses.reply` | Reply |
| `recording_studio.ai.retained_responses.structured_reply` | Structured reply |
| `recording_studio.ai.retained_responses.provider_payload` | Provider payload |

Left untranslated on purpose: reply body and structured/provider JSON (user /
model content), humanized response types, size and expiry values, content-type
strings, icon/style tokens, and Admin widget copy under `lib/` (out of scope).

### Upgrade steps

No migration is required. English hosts need no change. To override or add
another language, set the keys above in the host's `config/locales`.

## Upgrading to 0.7.0

`0.7.0` can meter each external provider attempt before the provider runs. When a handler is set, `submit_batch` spends once after the local batch row exists and before provider HTTP. There is no migration. Leave `usage_handler` and `usage_key_resolver` nil to keep attempts and batch submit unmetered.

1. Update the host dependency to `recording_studio_ai`, `~> 0.7.0`.
2. Assign both procs when the host should charge credits. The resolver requires `provider_native_tools:`. A strict lambda that omits it raises `ArgumentError` and the provider does not run. Lambdas that take `**` already accept it. There is no compatibility shim. A nil resolver result leaves that attempt, or that batch submission, unmetered.

```ruby
RecordingStudioAI.configure do |config|
  config.usage_key_resolver = lambda do |operation:, provider:, model:, profile:, purpose:, attribution:, provider_native_tools:|
    case [operation, provider.to_s, model.to_s]
    when ["decision", "typesafe", "jev-latest"]
      "ai.jev"
    else
      case provider.to_s
      when "gemini"
        if model.to_s.include?("flash")
          provider_native_tools.include?(:web_search) ? "ai.gemini_flash_search" : "ai.gemini_flash"
        end
      when "openai"
        "ai.openai"
      end
    end
  end

  config.usage_handler = lambda do |key:, quantity:, attribution:, idempotency_key:, metadata:|
    RecordingStudioStripe::Billing
      .for_recording(attribution.root_recording)
      .line(:pressbot)
      .spend_usage(key:, quantity:, idempotency_key:)
  end
end
```

Hosts with more than one subscription line call `.line`. Unscoped `spend_usage` raises `AmbiguousSubscriptionLine` when more than one live plan holds credits. It raises `SubscriptionLineRequired` when more than one subscription type is configured and no live plan holds credits.

The AI gem does not know credit rates. `ai.jev`, `ai.gemini_flash`, and `ai.gemini_flash_search` are keys the host may return. The gem does not hard-code those keys. Recording Studio Stripe `usage_costs` turns a key into credits. Token columns and `CostCalculator` stay. The resolver value is `[]` or `[:web_search]`. Metadata `provider_native_tools` is an array of name strings. It does not include prompts, queries, or bodies. The charge follows the request, not whether the provider later used the tool.

A handler exception propagates unchanged, and the provider call does not run. There is no refund if the provider fails after the handler returns. Each attempt spends once, including retries, fallbacks, and tool continuations. The idempotency key is `ai-attempt:<attempt id>`.

When a handler is set, `submit_batch` spends once. Quantity is the item count. The idempotency key is `ai-batch:<batch id>:submission`. The operation is `batch`. Purpose is nil. `provider_native_tools` is the union of requested tools. A mixed batch shares one key. Hosts who need different tariffs submit separate batches. One combined key is enough. Separate events per tool could be added later.

A handler exception from `submit_batch` propagates unchanged. The provider is not called. The batch, items, and runs are `usage` / `usage_declined`. A nil handler leaves batch submit unmetered. A nil resolver result leaves that submission unmetered. Refresh, cancel, polling, webhook sync, `perform_tool`, and local tool execution stay unmetered.

## Upgrading to 0.6.0

`0.6.0` adds `RecordingStudioAI.perform_tool`. A host can run one registered tool without calling a model. `generate` and `decide` are unchanged.

1. Update the host dependency to `recording_studio_ai`, `~> 0.6.0`.
2. Run `bin/rails recording_studio_ai:install:migrations` and `bin/rails db:migrate`. The migration allows run operation `tool` and adds `arguments` and `result` on custom tool invocations.
3. No configuration change. Tools that require confirmation still use `custom_tool_confirmation_handler`.
4. Call `perform_tool` with a stable `request_id`. Call it again with `resume: true` and `arguments: nil` to continue a pending confirmation. A finished `request_id` returns the stored outcome and does not run the tool again.

## Upgrading to 0.5.0

`0.5.0` adds a Profiles screen to Recording Studio Admin. Calls, profiles, and model resolution are unchanged.

1. Update the host dependency to `recording_studio_ai`, `~> 0.5.0`.
2. Open the Recording Studio AI section and choose Profiles. The table lists each profile's models and whether they are used for generative or decision calls.

## Upgrading to 0.4.0

`0.4.0` adds `RecordingStudioAI.decide`. Generation, streaming, and batches stay on OpenAI and Gemini. Jev is decision-only.

1. Update the host dependency to `recording_studio_ai`, `~> 0.4.0`.
2. Set `config.typesafe_api_key` from `TYPESAFE_API_KEY` and add `:typesafe` to `allowed_provider_overrides` before calling `decide`.
3. Leave the key unset if the host does not make decisions. Jev drops out of resolution, and `generate` is unchanged.
4. The default decision caps are 20 questions, 60,000 state characters, 4,000 characters per instruction or criterion, and 80,000 characters combined. Raise `maximum_decision_questions` for a larger set, and raise `maximum_decision_characters` when those questions are long.
5. A profile fallback that names the same provider and model twice now runs that candidate once. Retries still use `maximum_retries_per_candidate`.

## Upgrading to 0.3.2

`0.3.2` removes the engine staff app. Point people at Recording Studio Admin.
Saved replies move. Four engine-admin config keys go away.

1. Update the host dependency to `recording_studio_ai`, `~> 0.3.2`.
2. Install and mount Recording Studio Admin if the host does not already.
   Enable the `recording_studio_ai` section and grant Accessible access. Staff
   open `/admin`. There is no `/recording_studio_ai/admin` route and no
   redirect from the old path.
3. Delete `config.admin_layout`, `config.admin_authenticate`,
   `config.admin_actor_resolver`, and `config.admin_visible_roots_resolver`.
   Keep `admin_warning_thresholds`, `admin_slow_call_threshold_ms`, and
   `admin_expensive_models` if you set them.
4. Bookmark saved replies at `/recording_studio_ai/retained_responses/:id`
   instead of `/recording_studio_ai/admin/retained_responses/:id`. Decrypt
   still requires `recording_studio_ai.view_retained_response` (Accessible
   `:admin`). Listing stays on the Admin surface role (default `:view`).
5. Remove any host code that mounted, linked to, or authenticated
   `RecordingStudioAI::Admin`. Provider batches and web-search used live on
   Admin screens (`provider_batches`, `ai_calls?web_search=1`).

## Upgrading to 0.3.1

`0.3.1` only changes Cloud Agent boot. There is no host, schema, or in-app AI
product change. Update the host dependency to `recording_studio_ai`, `~> 0.3.1`
when you want this boot pack. Rebuild the Cloud Agent environment with Draft
off so Build loads the fetched skills.

Actors still go through Accessible and API. The public contracts from `0.3.0`
are unchanged.

## Upgrading to 0.3.0

`0.3.0` pins this engine onto Recording Studio 4.2. Update the host dependency to
`recording_studio_ai`, `~> 0.3.0`, then apply the steps below.

1. Upgrade Recording Studio to `4.2.0` or newer (`~> 4.2`) before installing this
   gem. Matching dummy/dev tags are Recording Studio `v4.4.0`, Accessible
   `v0.7.0`, Admin `2.0.1`, Root Switchable `v0.5.0`, and FlatPack `v0.1.143`.
   This gem does not declare Accessible in the gemspec; hosts that use Accessible
   authorization should pin it themselves.
2. Run the Recording Studio 4.0 harden-indexes migration in the host
   (`rails g recording_studio:migrations` or copy
   `harden_recording_studio_indexes_and_constraints`) and `bin/rails db:migrate`.
3. Enable Accessible with `RecordingStudio.enable_capability(:accessible, on: Type)`
   (or `config.enable_capability`) on each recordable that should hold grants.
4. Keep the host app's own sidebar (or other shell) for host pages. Include
   `RecordingStudio::UsesDefaultLayout` on this gem's engine admin and on
   Recording Studio Admin screens so those use `recording_studio/default_layout`.
   Recording Studio 4.2 applies `data-theme="rounded"` on `body`; hosts that
   still key FlatPack off `html` can stamp `html data-theme="rounded"` without
   copying the layout. Do not vendor `recording_studio/default_layout`. Put
   Access in the gem page-nav right slot; do not put Sign out, Root Switchable,
   or an admin/root dropdown there. Host `_default_layout_head` should load
   application, `flat_pack/variables`, `flat_pack/rich_text`, Tailwind, and
   importmap so FlatPack Tables render. Engine admin screens in this gem pass
   FlatPack column `html:` lambdas (returning a string) so table cells land
   under headers; ERB `<% table.column do |row| %>` blocks dump cell HTML
   above an empty table on FlatPack 0.1.143. Engine admin discards leftover
   Devise `notice` flash (hosts that include `UsesDefaultLayout` on Recording
   Studio Admin can do the same). Overview formats `error_rate` and
   `provider_error_rate` as percentages.
5. First owner grants: `RecordingStudioAccessible.bootstrap_owner_access!` on an
   empty owned root. Later members: `grant_access`. Persist the actor and
   recording before either call. Set `access_actor_types` so `User` can hold
   grants.
6. FlatPack 0.1.143 buttons use `href:` (not `url:`). If Recording Studio 4.2
   still passes PageNav `anchor_url:`, alias it to `anchor_href:` in the host —
   do not fork the layout. Admin 2.0.1 section views still pass Button `url:`;
   hosts can alias that to `href:` the same way.
7. Point `config.admin_layout` at `recording_studio/default_layout` so engine
   admin uses the gem shell instead of the host sidebar.
