# Recording Studio AI Dummy Host

This Rails app validates the addon in a real Recording Studio host application.

It covers:

- loading and mounting `RecordingStudioAI::Engine`
- the generated addon initializer
- Devise authentication and `Current.actor` wiring
- Recording Studio 6.1 recordable declarations and root recordings
- the dummy host `flat_pack_sidebar` shell for host pages (rounded `html` /
  `body`)
- `recording_studio_layout` on the saved-reply page and Admin's default
  engine layout (`recording_studio/default_layout`, no vendored copy)
- Accessible first-owner bootstrap and later grants
- all six non-recordable addon infrastructure tables
- Recording Studio Admin as the only staff hub
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
- `/decision_playground` runs `RecordingStudioAI.decide`
- `/config` — initializer and registry guide
- `/methods` — call-site examples
- `/admin` — Recording Studio Admin AI screens
- `/recording_studio_ai/retained_responses/:id` — saved reply (decrypt)
  (gem view copy uses `recording_studio.ai.retained_responses` English I18n keys)
- `/recording_studio` — Recording Studio host integration
- `/users/sign_in` — Devise sign in
- `/up` — Rails health check

Authenticated host pages use `layouts/flat_pack_sidebar` (sidebar + top nav,
theme `rounded` on `html` and `body`). Recording Studio Admin (`/admin`) uses
its default engine layout, and the saved-reply controller calls
`recording_studio_layout`. Both render `recording_studio/default_layout`.
The layout loads Flatpack stylesheets before Tailwind. Dummy
`app/views/recording_studio/_default_layout_head.html.erb` adds the host
application stylesheet and importmap. The gem page-nav right slot is Access
only. No Sign out, Root Switchable, or admin/root dropdown. Devise sign-in
keeps `layouts/application`. The dummy translates Admin's
`recording_studio_page_nav` onto `flat_pack_page_nav`, and maps leftover
Card `style:`, PageNav `anchor_label:`, and Button `url:` from pinned
sibling gems. That translation does not copy Admin's `title:` into
`content_for :title`, so Admin keeps its own heading as the only `h1` and
the document title stays the app name. Admin and the saved-reply page discard leftover Devise
sign-in notices.
