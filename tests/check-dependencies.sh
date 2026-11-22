#!/usr/bin/env bash
# Fail fast when CI dependencies become mutable or unreviewed.
set -euo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$root"
[[ "$(find .github/workflows -maxdepth 1 -name '*.yml' | wc -l | tr -d ' ')" == 1 ]] || {
  echo 'Expected one consolidated workflow. Remove redundant workflows.' >&2; exit 1;
}
# Every GitHub Action must be pinned to a complete commit SHA.
# mawk does not support {40}; use grep for portable matching.
if grep -E '^[[:space:]]*- uses:' .github/workflows/ci.yml | grep -Ev '@[0-9a-f]{40}([[:space:]]|$)'; then
  echo 'CI action pin policy violated' >&2
  exit 1
fi
if grep -R -nE 'curl[[:space:]].*(--insecure|(^|[[:space:]])-k([[:space:]]|$))' gitwo tests/e2e --include='*.sh'; then
  echo 'TLS verification bypass detected' >&2; exit 1
fi
grep -Fq 'GITWO_E2E_RAILS_VERSION:-7.2.4' tests/e2e/rails-postgres.sh || {
  echo 'Default Rails fixture version changed unexpectedly' >&2; exit 1;
}
grep -Fq "GITWO_E2E_RAILS_VERSION: '8.1.4.1'" .github/workflows/ci.yml || {
  echo 'Pinned Rails 8.1 E2E missing' >&2; exit 1;
}
grep -Fq "GITWO_E2E_RSPEC_RAILS_VERSION: '8.1.0'" .github/workflows/ci.yml || {
  echo 'Pinned rspec-rails version missing' >&2; exit 1;
}
grep -q 'portless@0.18.1' .github/workflows/ci.yml || {
  echo 'Portless must have an explicit reviewed npm version' >&2; exit 1;
}
printf '[PASS] Dependency pinning, Rails fixture and TLS policy\n'
