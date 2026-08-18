Recording Studio AI installation complete.

Next steps:

1. Review `config/initializers/recording_studio_ai.rb`.
2. Configure at least one OpenAI or Gemini credential.
3. Confirm Recording Studio is configured in the host application.
4. Review the generated engine mount path in `config/routes.rb`.
5. Configure the authorization handler. It denies every action by default.
	Install recording-studio-accessible, then prefer:

```ruby
config.authorization_handler = RecordingStudioAI::AccessibleAuthorization.method(:call)
```

	That mapper separates view / execute / confirm / sensitive / retained onto
	Accessible `:view` / `:edit` / `:admin`. Never use `->(**) { true }`.
6. Install and apply addon migrations:

```bash
bin/rails recording_studio_ai:install:migrations
bin/rails db:migrate
```

Profiles select configured OpenAI and Gemini candidates by capability. The
OpenAI SDK is installed with the addon; Gemini uses the provider's REST API.
Provider overrides remain disabled unless explicitly enabled in the initializer.

To synchronize an active provider batch until it reaches a terminal status,
enqueue `RecordingStudioAI::BatchSynchronizationJob` with `batch_id`,
`root_recording`, and `initiator`. The job carries attribution explicitly and
uses `batch_synchronization_interval` between provider refreshes.

The response table uses Active Record Encryption. Configure
`active_record_encryption.primary_key`, `deterministic_key`, and
`key_derivation_salt` in encrypted Rails credentials before enabling response
retention. Rotate keys with Rails' `previous` encryption schemes, retain old
keys until all retained rows encrypted by them have expired, and verify reads
before removing an old key.

Response retention is disabled by default. If enabled, schedule
`RecordingStudioAI::ResponseCleanupJob` or
`bin/rails recording_studio_ai:cleanup_responses`, and monitor job failures and
the count of rows past `expires_at`. Provider-uploaded attachments may remain
subject to provider-side retention even though this addon never stores their
bytes or filenames.

For Rails 8 applications using Solid Queue, add this recurring task to
`config/recurring.yml`:

```yaml
recording_studio_ai_response_cleanup:
	class: RecordingStudioAI::ResponseCleanupJob
	schedule: every hour
```

For cron-based hosts, run the idempotent cleanup task hourly:

```cron
17 * * * * cd /path/to/app && bin/rails recording_studio_ai:cleanup_responses
```

Canonical execution history has a separate, disabled-by-default policy. Set
`execution_history_retention_period` to a positive duration and schedule
`RecordingStudioAI::HistoryCleanupJob` or
`bin/rails recording_studio_ai:cleanup_history`. The cleanup transaction removes
only terminal history older than the cutoff, deleting responses and dependent
records before runs and batches to preserve foreign-key integrity.

Admin access also fails closed. Configure `admin_actor_resolver`,
`admin_visible_roots_resolver`, and, when needed, `admin_layout`. The engine does
not authenticate admin routes by itself — authenticate in
`ApplicationController` and/or set `admin_authenticate`. Grant basic,
sensitive, and retained-response actions independently.

Review the generated attachment count, size, and content-type limits before
accepting request-scoped files. Attachment bytes and filenames are not persisted.

Before rollback, stop execution and cleanup jobs, remove addon foreign-key
dependents according to the host retention policy, then run `bin/rails db:rollback`.
Rollback deletes addon execution history and retained responses; it must not
delete Recording Studio recordings or events.
