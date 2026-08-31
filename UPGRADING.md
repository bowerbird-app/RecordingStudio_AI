# Upgrading RecordingStudioAI

## Upgrading to 0.3.0

`0.3.0` pins this engine onto Recording Studio 4.2. Update the host dependency to
`recording_studio_ai`, `~> 0.3.0`, then apply the steps below.

1. Upgrade Recording Studio to `4.2.0` or newer (`~> 4.2`) before installing this
   gem. Matching dummy/dev tags are Recording Studio `v4.2.0`, Accessible
   `v0.7.0`, Admin `2.0.1`, Root Switchable `v0.5.0`, and FlatPack `v0.1.143`.
   This gem does not declare Accessible in the gemspec; hosts that use Accessible
   authorization should pin it themselves.
2. Run the Recording Studio 4.0 harden-indexes migration in the host
   (`rails g recording_studio:migrations` or copy
   `harden_recording_studio_indexes_and_constraints`) and `bin/rails db:migrate`.
3. Enable Accessible with `RecordingStudio.enable_capability(:accessible, on: Type)`
   (or `config.enable_capability`) on each recordable that should hold grants.
4. Include `RecordingStudio::UsesDefaultLayout` on authenticated host controllers
   (or keep `layout "recording_studio/default_layout"`). Recording Studio 4.2
   applies `data-theme="rounded"` on `body`; hosts that still key FlatPack off
   `html` can stamp `html data-theme="rounded"` without copying the layout. Do
   not vendor `recording_studio/default_layout`. Put Access in the page-nav right
   slot; do not put Sign out, Root Switchable, or an admin/root dropdown there.
5. First owner grants: `RecordingStudioAccessible.bootstrap_owner_access!` on an
   empty owned root. Later members: `grant_access`. Persist the actor and
   recording before either call. Set `access_actor_types` so `User` can hold
   grants.
6. FlatPack 0.1.143 buttons use `href:` (not `url:`). If Recording Studio 4.2
   still passes PageNav `anchor_url:`, alias it to `anchor_href:` in the host —
   do not fork the layout. Admin 2.0.1 section views still pass Button `url:`;
   hosts can alias that to `href:` the same way.
7. Point `config.admin_layout` at `recording_studio/default_layout` (or leave it
   nil so authenticated controllers inherit the default layout).
