# Recording Studio AI

`recording_studio_ai` is an isolated Rails engine for adding AI capabilities to
[Recording Studio](https://github.com/bowerbird-app/RecordingStudio).

This repository currently contains the Phase 1 foundation only. It does not yet
expose generation, streaming, batch, or response APIs and installs no database
tables.

## Requirements

- Ruby 3.3 or newer
- Rails 8.1
- Recording Studio 3.x

Runtime dependencies are intentionally limited to Rails and Recording Studio.
Phase 1 does not select an AI provider or depend on a provider SDK.

## Installation

Add the addon and Recording Studio v3 to the host application's `Gemfile`:

```ruby
gem "recording_studio",
    github: "bowerbird-app/RecordingStudio",
    tag: "recording_studio/v3.0.0"
gem "recording_studio_ai",
    github: "bowerbird-app/RecordingStudio_AI"
```

Then install the foundation:

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

No migration command is required.

## Configuration

Prefer Rails credentials for secrets:

```yaml
openai:
  api_key: your-openai-key
gemini:
  api_key: your-gemini-key
```

Neither credential is required for the Phase 1 foundation. The generated
initializer accepts OpenAI and Gemini credentials symmetrically through Rails
credentials or `OPENAI_API_KEY` and `GEMINI_API_KEY`:

```ruby
RecordingStudioAI.configure do |config|
  config.openai_api_key =
    Rails.application.credentials.dig(:openai, :api_key) ||
      ENV.fetch("OPENAI_API_KEY", nil)
  config.gemini_api_key =
    Rails.application.credentials.dig(:gemini, :api_key) ||
      ENV.fetch("GEMINI_API_KEY", nil)

  # Client objects can be injected once provider adapters are available.
  # config.openai_client = MyOpenAIClientFactory.build
  # config.gemini_client = MyGeminiClientFactory.build

  config.default_profile = :medium
  config.retain_responses = false
  config.response_retention_period = 7.days
  config.maximum_retained_response_size = 1.megabyte
  config.maximum_attempts = 3
  config.maximum_retries_per_candidate = 1
  config.maximum_provider_fallbacks = 1
  config.maximum_custom_tool_rounds = 5
  config.request_timeout = 120
end
```

These settings establish V1 defaults only. Provider adapters and execution
behavior are intentionally deferred to a later phase.

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

The dummy app preserves Recording Studio v3 declarations, actor wiring, root
recordings, authentication, and the mounted addon route.

The original template documentation remains under `docs/gem_template/` as
architectural reference only.
