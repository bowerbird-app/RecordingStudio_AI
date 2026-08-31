# Recording Studio AI Dummy Host

This Rails app validates the addon in a real Recording Studio host application.

It covers:

- loading and mounting `RecordingStudioAI::Engine`
- the generated addon initializer
- Devise authentication and `Current.actor` wiring
- Recording Studio 4.2 recordable declarations and root recordings
- `RecordingStudio::UsesDefaultLayout` from the Recording Studio gem (rounded
  theme on `html` / `body`; no vendored layout copy)
- Accessible first-owner bootstrap and later grants
- all six non-recordable addon infrastructure tables
- the mounted, GET-only addon administration screens
- fail-closed production configuration with an explicit demo-only authorization policy

Tests use injected provider clients; live generation requires provider credentials.

## Run the host

```bash
cd test/dummy
bundle install
bin/rails db:setup
bin/dev
```

Open `/ai_playground` and sign in with:

- Email: `admin@admin.com`
- Password: `Password`

Forwarded preview URLs (Codespaces, Cursor Cloud) can reject sign-in with a CSRF
origin mismatch. The dummy relaxes that origin check in development when
`CODESPACES=true` or `CURSOR_AGENT` is set. CSRF tokens stay required.

Useful routes:

- `/ai_playground` — generate against a profile model
- `/config` — initializer and registry guide
- `/methods` — call-site examples
- `/recording_studio_ai/admin` — engine administration
- `/admin` — Recording Studio Admin AI screens
- `/recording_studio` — Recording Studio host integration
- `/users/sign_in` — Devise sign in
- `/up` — Rails health check

Authenticated pages include `RecordingStudio::UsesDefaultLayout` and render the
gem's `recording_studio/default_layout` (theme `rounded` on `body`; dummy also
stamps `data-theme="rounded"` on `html`). The page-nav right slot is Access
only. Devise sign-in keeps `layouts/application`. Dummy-only FlatPack aliases
map PageNav `anchor_url:` to `anchor_href:` and Button `url:` to `href:` so
Recording Studio 4.2 and Admin 2.0.1 keep working against FlatPack 0.1.143
without forking the layout.
