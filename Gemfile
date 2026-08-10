# frozen_string_literal: true

source "https://rubygems.org"

# Recording Studio is pinned here because its v3 source is currently distributed
# from GitHub. The runtime constraint is declared in the gemspec.
gem "recording_studio",
    github: "bowerbird-app/RecordingStudio",
    tag: "recording_studio/v3.0.0"

gemspec

gem "puma"
gem "sprockets-rails"

group :development, :test do
  gem "debug"
  gem "simplecov", require: false
end

group :development do
  gem "rubocop", require: false
  gem "rubocop-rails", require: false
end
