#!/usr/bin/env bash
# Cloud Agent start phase: ensure PostgreSQL is running on every boot.
# The database cluster lives on disk (captured by the environment snapshot),
# but the server process must be (re)started each time the VM boots.
set -euo pipefail

sudo pg_ctlcluster 16 main start 2>/dev/null || true
for _ in $(seq 1 30); do
  if pg_isready -h localhost -q; then
    exit 0
  fi
  sleep 1
done

echo "PostgreSQL did not become ready in time" >&2
exit 1
