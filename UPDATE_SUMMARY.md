# RecordingStudio AI English-fallback update summary

## Current branch summary

This branch adds English fallback for missing `recording_studio.ai.*` keys via
RecordingStudio `~> 4.7` (`v4.7.0` / `613501c`): `RecordingStudio.t` and
`RecordingStudio::Translation.register_shipped_english`.

### Dependency changes

- Gemspec requires `recording_studio ~> 4.7`.
- Root and dummy Gemfiles pin RecordingStudio to tag `v4.7.0`.
- Lockfiles differ from `main` only for RecordingStudio `4.7.0` (`613501c`),
  this gem's version (`0.12.0`), and the `~> 4.7` dependency line.
- Gem version is `0.12.0`.

### Behavior

- Engine registers `config/locales/en.yml` at boot before
  `recording_studio.load_shipped_english`.
- Gem chrome uses `RecordingStudio.t` / `Copy.t` for `recording_studio.ai.*`
  keys only. Host or other-namespace keys stay on `I18n.t` with main's
  `default:`.
- No gem-local Translation helper.
- `en.yml` is byte-identical to `main`.
- Dynamic unknown attempt kinds / prompt roles keep main's
  `Copy.t(..., default: english)` (same English constants / `humanize`).

### Upgrade note (`_html`)

A missing `_html` key with a caller `default:` follows `RecordingStudio.t` /
view `t` escaping. A plain `default:` with no interpolation is returned as a
plain (non-`html_safe`) String, so views will escape it.

### Verification (HEAD before push)

| Suite | Seed | Result |
| --- | --- | --- |
| `admin_i18n` + `profile_kind_i18n` + `locales` | 8600 | 25 runs, 780 assertions, 0 failures |
| gem `rake test` | 1 | 491 runs, 4373 assertions, 0 failures, 1 skip |
| gem `rake test` | 8600 | 491 runs, 4373 assertions, 0 failures, 1 skip |
| dummy `ai_i18n_english_fallback_test` | 1 | 5 runs, 51 assertions, 0 failures |

Also green locally: seeds `17`, `42`, `99` on admin/profile/locales widget Copy.t coverage.
