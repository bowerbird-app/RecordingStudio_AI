# frozen_string_literal: true

source "https://rubygems.org"

# Recording Studio is pinned here because its source is currently distributed
# from GitHub. The runtime constraint is declared in the gemspec.
gem "recording_studio", "~> 7.8", github: "bowerbird-app/RecordingStudio", tag: "v7.8.0"
gem "flat_pack", "~> 0.2", github: "bowerbird-app/flatpack", tag: "v0.2.0"
gem "view_component", "4.19.0"
gem "recording_studio_logs", "~> 0.9", github: "bowerbird-app/RecordingStudio_logs", tag: "v0.9.0"
gem "recording_studio_metrics", "~> 0.10", github: "bowerbird-app/RecordingStudio_metrics", tag: "v0.10.0"

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
