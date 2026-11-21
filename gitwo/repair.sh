#!/usr/bin/env bash
# Read-only recovery plan for metadata/database/bootstrap mismatch.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/_common.sh"
usage() { printf 'Usage: gitwo repair [WORKSPACE]\nInspect state and print safe recovery steps. This command NEVER changes data.\n'; }
if [[ "${1:-}" == -h || "${1:-}" == --help ]]; then usage; exit 0; fi
[[ $# -le 1 ]] || { usage >&2; exit 2; }
gitwo_check_source
target="$(gitwo_resolve_path "${1:-}")"
branch="$(git -C "$target" branch --show-current)"
gitwo_verify_target "$target" "$branch"
gitwo_validate_workspace_identity "$target" "$branch"
slug="$(basename "$target")"
state_file="$(gitwo_state_path "$target")"
marker="$GITWO_STATE/$slug.db-ready"
bootstrap="$GITWO_STATE/$slug.bootstrap-status"
seed="$GITWO_STATE/$slug.seed-status"
expected="$(gitwo_expected_db_name "$target" development)"
issues=0
printf 'Gitwo / read-only repair plan for %s\n' "$slug"
for path in "$state_file" "$marker" "$bootstrap" "$seed"; do
  if [[ -L "$path" ]]; then
    printf '  ERROR: Unsafe symlink: %s\n' "$path"
    issues=$((issues+1))
  fi
done
if [[ -f "$bootstrap" && ! -L "$bootstrap" ]]; then
  case "$(cat "$bootstrap")" in
    failed|running)
      printf '  ATTENTION: Bootstrap is incomplete (%s). Inspect before explicit DB rebuild.\n' "$(cat "$bootstrap")"
      issues=$((issues+1)) ;;
    ready) printf '  Bootstrap: completed\n' ;;
    *) printf '  ERROR: Unexpected bootstrap metadata\n'; issues=$((issues+1)) ;;
  esac
fi
if [[ -f "$seed" && ! -L "$seed" ]]; then
  case "$(cat "$seed")" in
    failed|running)
      printf '  ATTENTION: Seeds were interrupted. Do not rerun non-idempotent seeds automatically.\n'
      issues=$((issues+1)) ;;
    ready) printf '  Seeds: recorded as completed\n' ;;
    *) printf '  ERROR: Unexpected seed metadata\n'; issues=$((issues+1)) ;;
  esac
fi
if [[ -f "$marker" && ! -L "$marker" && "$(cat "$marker")" != "$expected" ]]; then
  printf '  ERROR: DB ownership marker differs from expected %s\n' "$expected"
  issues=$((issues+1))
fi
if [[ ! -f "$state_file" || ! -f "$marker" ]]; then
  printf '  Missing registration metadata. For an existing verified DB use: gitwo init %s --adopt-db\n' "$slug"
  issues=$((issues+1))
else
  printf '  Workspace registration files: present\n'
fi
if command -v psql >/dev/null 2>&1; then
  gitwo_db_settings
  present="$(gitwo_pg psql --no-psqlrc -w -d postgres -Atqc "SELECT 1 FROM pg_database WHERE datname = '$expected'" 2>/dev/null)" || present=unavailable
  case "$present" in
    1) printf '  PostgreSQL database: exists (%s)\n' "$expected" ;;
    '') printf '  ATTENTION: DB absent. Do not recreate over existing metadata without inspection.\n'; issues=$((issues+1)) ;;
    *) printf '  PostgreSQL unreachable; could not inspect DB.\n'; issues=$((issues+1)) ;;
  esac
else
  printf '  PostgreSQL tools unavailable\n'; issues=$((issues+1))
fi
if (( issues == 0 )); then
  gitwo_ok 'No obvious state/ownership problem found. For runtime failures run gitwo doctor --deps and gitwo status --check-http.'
else
  gitwo_warn "Found $issues issue(s). No files or databases changed. Review before any explicit rebuild."
fi
exit "$((issues > 0))"
