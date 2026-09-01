# Recording Studio AI Dummy Host

This Rails app validates the addon in a real Recording Studio host application.

It covers:

- loading and mounting `RecordingStudioAI::Engine`
- the generated addon initializer
- Devise authentication and `Current.actor` wiring
- Recording Studio 4.2 recordable declarations and root recordings
- the dummy host `flat_pack_sidebar` shell for host pages (rounded `html` /
  `body`)
- `RecordingStudio::UsesDefaultLayout` on engine admin and Recording Studio
  Admin AI screens only (`recording_studio/default_layout`, no vendored copy)
- Accessible first-owner bootstrap and later grants
- all six non-recordable addon infrastructure tables
- the mounted Recording Studio Admin AI screens plus engine admin show/overview
  drill-downs
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
- `/recording_studio_ai/admin` — engine admin overview and show drill-downs
- `/admin` — Recording Studio Admin AI list/analytics screens
- `/admin/screens/provider_batches` — provider batches index
- `/recording_studio` — Recording Studio host integration
- `/users/sign_in` — Devise sign in
- `/up` — Rails health check

Authenticated host pages use `layouts/flat_pack_sidebar` (sidebar + top nav,
theme `rounded` on `html` and `body`). Engine admin (`/recording_studio_ai/admin`)
and Recording Studio Admin (`/admin`) include `RecordingStudio::UsesDefaultLayout`
and render the gem's `recording_studio/default_layout`. Dummy
`app/views/recording_studio/_default_layout_head.html.erb` loads application,
`flat_pack/variables`, `flat_pack/rich_text`, Tailwind, and importmap so FlatPack
Tables render. Engine admin tables pass FlatPack column `html:` lambdas so
cells land under headers, and those tables are not wrapped in a Card. The gem page-nav right slot is Access only — no Sign out, Root
Switchable, or admin/root dropdown. Devise sign-in keeps `layouts/application`.
Dummy-only FlatPack aliases map PageNav `anchor_url:` to `anchor_href:` and
Button `url:` to `href:` so Recording Studio 4.2 and Admin 2.0.1 keep working
against FlatPack 0.1.143 without forking the layout. Gem admin discards leftover
Devise sign-in notices. Overview formats warning rates as percentages.
