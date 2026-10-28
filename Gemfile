# frozen_string_literal: true

source "https://rubygems.org"

require_relative "test/support/widen_recording_studio_requirement"

# Recording Studio is pinned here because its source is currently distributed
# from GitHub. The runtime constraint is declared in the gemspec.
gem "recording_studio",
    github: "bowerbird-app/RecordingStudio",
    tag: "v6.1.0"
gem "flat_pack",
    github: "bowerbird-app/flatpack",
    ref: "1fcbafe94f8eb118f0a22182f63f5110fcc97a56"
gem "view_component", "4.19.0"
gem "recording_studio_logs",
    github: "bowerbird-app/RecordingStudio_logs",
    tag: "v0.5.0"
gem "recording_studio_metrics",
    github: "bowerbird-app/RecordingStudio_metrics",
    tag: "v0.5.0"

gemspec

gem "puma"
gem "sprockets-rails"

group :development, :test do
  gem "debug"
  gem "minitest-mock", require: false
  gem "simplecov", require: false
  gem "sqlite3"
end

group :development do
  gem "rubocop", require: false
  gem "rubocop-rails", require: false
end
