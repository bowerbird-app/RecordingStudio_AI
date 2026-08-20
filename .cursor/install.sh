#!/usr/bin/env bash
# Cloud Agent install phase for the RecordingStudio_AI gem template.
# Refreshes gem dependencies, prepares the dummy host-app database, and
# builds Tailwind CSS. Safe to run repeatedly (idempotent).
set -euo pipefail

# db:prepare needs PostgreSQL up during install/build. Starting an already
# running cluster is a no-op error, so ignore it and then wait for readiness.
sudo pg_ctlcluster 16 main start 2>/dev/null || true
for _ in $(seq 1 30); do
  pg_isready -h localhost -q && break
  sleep 1
done

# Root engine dependencies (used by `rake test`/`rubocop`).
bundle install

# foreman powers the dummy app's `bin/dev` (web server + Tailwind watch).
gem list -i foreman >/dev/null 2>&1 || gem install foreman --no-document

# Dummy host app: dependencies, database (create + migrate + seed), assets.
cd test/dummy
bundle install
bin/rails db:prepare
bin/rails tailwindcss:build
