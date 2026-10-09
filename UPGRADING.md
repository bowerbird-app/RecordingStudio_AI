# Upgrading RecordingStudioAI

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
