# frozen_string_literal: true

source "https://rubygems.org"

# Recording Studio is pinned here because its source is currently distributed
# from GitHub. The runtime constraint is declared in the gemspec.
gem "recording_studio",
    github: "bowerbird-app/RecordingStudio",
    tag: "v4.2.0"
gem "flat_pack",
    github: "bowerbird-app/flatpack",
    tag: "v0.1.143"

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
