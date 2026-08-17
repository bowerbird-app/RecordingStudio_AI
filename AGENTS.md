# AGENTS.md

## Cursor Cloud specific instructions

This repo is a Rails 8.1 engine gem (`gem_template`) plus a dummy host app in `test/dummy`. The
dummy app is the runnable application; the gem itself is a library. Standard commands live in the
root `Rakefile`, `.github/workflows/ci.yml`, and `README.md` — refer to those rather than
duplicating them here.

### Toolchain / services (already provisioned in the base snapshot)

- Ruby `3.3.6` is installed via [`mise`](https://mise.jdx.dev/) (see `.ruby-version`). The shims
  live in `~/.local/share/mise/shims` and are added to `PATH` in `~/.bashrc`. Interactive shells get
  Ruby automatically; non-interactive scripts should prepend that shims dir to `PATH`.
- PostgreSQL 16 is installed but is **not** started automatically on a fresh VM (no systemd in the
  container). Start it before running the DB, tests, or the server:
  `sudo pg_ctlcluster 16 main start`. The `postgres` role password is `postgres`, matching the
  defaults in `test/dummy/config/database.yml` (host `localhost`, port `5432`).

### Gems / private dependencies

- The dummy app depends on private `bowerbird-app` GitHub repos (`recording_studio`,
  `recording_studio_accessible`, `recording_studio_root_switchable`, `flat_pack`). Cursor's managed
  git config rewrites `github.com` URLs with an access token each session, so `bundle install`
  resolves these automatically — no `BUNDLE_GITHUB__COM` needed (CI uses that secret instead).
- Two separate bundles: the root `Gemfile` (gem + rubocop) and `test/dummy/Gemfile` (the app). The
  startup update script installs both.

### Running / testing / linting

- Lint (from repo root): `bundle exec rubocop`.
- Full test suite (from repo root, as CI runs it): `bundle exec rake test:all`. This prepares the
  dummy DB and runs gem + dummy tests under the dummy bundle.
- Dev server: `cd test/dummy && bin/dev` (foreman: Puma web on port 3000 + Tailwind CSS watch).
  First-time DB setup: `cd test/dummy && bin/rails db:prepare` (creates + seeds; seeds an admin
  `admin@admin.com` / `Password`). Rebuild CSS once with `bin/rails tailwindcss:build` if not using
  `bin/dev`.

### Known gotcha: Devise sign-in page 500s in the browser

`test/dummy/app/views/layouts/application.html.erb` calls
`Rails.application.assets&.find_asset("tailwind.css")`. This is a sprockets-era idiom;
with Propshaft (the pinned asset pipeline) `Rails.application.assets` is a `Propshaft::Assembly`,
which has no `find_asset`, so rendering raises `NoMethodError`. This layout is used **only** by
Devise controllers, so the browser sign-in page (`/users/sign_in`) returns HTTP 500. Authenticated
pages use the `flat_pack_sidebar` layout and render fine, which is why the whole test suite passes
(tests sign in via Devise helpers and never render the `application` layout). This is pre-existing
application code, not an environment problem; leave it unless a task explicitly asks to fix it.
