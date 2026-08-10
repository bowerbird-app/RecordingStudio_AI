# Recording Studio AI Dummy Host

This Rails app validates the Phase 1 addon foundation in a real Recording
Studio host application.

It covers:

- loading and mounting `RecordingStudioAI::Engine`
- the generated addon initializer
- Devise authentication and `Current.actor` wiring
- Recording Studio v3 recordable declarations and root recordings
- Recording Studio's root switcher and FlatPack host layout

It intentionally contains no Recording Studio AI generation UI, generation
endpoint, or addon database table.

## Run the host

```bash
cd test/dummy
bundle install
bin/rails db:setup
bin/dev
```

Open `/` and sign in with:

- Email: `admin@admin.com`
- Password: `Password`

Useful routes:

- `/` — foundation status page
- `/recording_studio_ai` — mounted isolated addon engine
- `/recording_studio` — Recording Studio host integration
- `/users/sign_in` — Devise sign in
- `/up` — Rails health check
