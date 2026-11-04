# RecordingStudio AI layout update

## Current release

`0.19.0` runs on Recording Studio `>= 6.1.0` (development tag `v6.1.0`) and Flatpack `>= 0.1.315` (development commit `1fcbafe94f8eb118f0a22182f63f5110fcc97a56`, version `0.1.319`). `view_component` is locked at `4.19.0`.

## Layout

`RecordingStudioAI::Configuration#layout` defaults to `nil`. Assignment goes through `RecordingStudio::Layout.accept`.

`RecordingStudioAI::RetainedResponsesController` calls `recording_studio_layout { RecordingStudioAI.configuration.layout }`. A `nil` setting uses `RecordingStudio.configuration.layout`, then `recording_studio/default_layout`. A String is the layout name. `false` renders no layout. A callable must take `controller:` and return a String, `nil`, or `false`.

The saved-reply view sets `content_for :title` and `content_for :subtitle`. Close uses `flat_pack_page_nav`. Access avatars use `recording_studio_page_nav_right`. Cards use `border:` and `shadow:`.

## Host dummy

The dummy sidebar stays the shell for playground, config, and methods. Admin `v2.7.0` and the saved-reply page use `recording_studio/default_layout`. Flatpack stylesheets load before Tailwind. The dummy has no `admin_audit_logs` table. `test/support/widen_recording_studio_requirement.rb` lets Bundler resolve Recording Studio 6.1.0 while sibling gems still declare a `< 5` requirement.

## Upgrade

See `UPGRADING.md` for `0.19.0`. No database migration.
