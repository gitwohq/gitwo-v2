#!/usr/bin/env bash
# Deliberately conservative worktree removal. Nothing is deleted without a typed confirmation.
# Keeps PostgreSQL databases and Git branches unless explicitly requested otherwise.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/_common.sh"
source "$GITWO_DIR/_runtime.sh"
source "$GITWO_DIR/_lifecycle.sh"
usage() { cat <<'USAGE'
Usage: gitwo remove [WORKSPACE] [--dry-run] [--delete-ignored] [--delete-db]
  --dry-run         Inspect without deleting anything
  --delete-ignored  Explicitly allow deletion of local ignored files (node_modules, credentials, etc.)
  --delete-db       Also drop the owned local development/test PostgreSQL databases
By default this keeps all PostgreSQL databases, Git branches, and Gitwo metadata.
Run `gitwo down` first. Tracked or untracked changes are NEVER deleted by Gitwo.
USAGE
}
selector='' dry_run=no delete_ignored=no delete_db=no
for arg in "$@"; do
  case "$arg" in
    -h|--help) usage; exit 0 ;;
    --dry-run) dry_run=yes ;;
    --delete-ignored) delete_ignored=yes ;;
    --delete-db) delete_db=yes ;;
    -*) usage >&2; gitwo_die "Unknown remove option: $arg" ;;
    *) [[ -z "$selector" ]] || { usage >&2; exit 2; }; selector="$arg" ;;
  esac
done
gitwo_need git
gitwo_check_source
target="$(gitwo_resolve_path "$selector")"
branch="$(git -C "$target" branch --show-current)"
gitwo_verify_target "$target" "$branch"
slug="$(basename "$target")"
# Only direct siblings under the legacy application root can be managed.
[[ "${target%/*}" == "$GITWO_ROOT" && "$target" != "$GITWO_SOURCE" ]] || gitwo_die 'Refusing to remove a non-Gitwo path'
gitwo_validate_workspace_identity "$target" "$branch"

changes="$(git -C "$target" status --porcelain --untracked-files=all)"
ignored="$(git -C "$target" ls-files --others --ignored --exclude-standard --directory)"
ignored_count=0
if [[ -n "$ignored" ]]; then ignored_count="$(printf '%s\n' "$ignored" | wc -l | tr -d ' ')"; fi
printf 'Gitwo workspace removal\n'
printf '  Workspace: %s\n  Branch:    %s (preserved)\n  Ignored:   %s paths\n  Database:  %s\n' "$target" "$branch" "$ignored_count" "$([[ "$delete_db" == yes ]] && echo 'purge requested' || echo 'preserved')"
if [[ -n "$changes" ]]; then
  gitwo_warn 'Tracked or untracked changes exist; removal is blocked (including with --delete-ignored).'
  printf '%s\n' "$changes" | head -n 20 >&2
  exit 1
fi
if [[ -n "$ignored" && "$delete_ignored" != yes ]]; then
  gitwo_warn 'Ignored files exist and git worktree remove would DELETE THEM, even without --force.'
  printf '%s\n' "$ignored" | head -n 15 >&2
  gitwo_warn 'Review these files and use --delete-ignored only if you consent to their deletion.'
  exit 1
fi

# Check for any running owned Redis, Puma or Sidekiq before acting.
puma_status="$(gitwo_puma_status "$target")"
redis_dev="$(gitwo_redis_process_status "$target" development)"
redis_test="$(gitwo_redis_process_status "$target" test)"
sidekiq_pids="$(gitwo_sidekiq_pids "$target")"
printf '  Puma:      %s\n  Redis dev: %s\n  Redis test:%s\n' "$puma_status" "$redis_dev" " $redis_test"
[[ -z "$sidekiq_pids" ]] || printf '  Sidekiq:   running (PID %s)\n' "$sidekiq_pids"
case "$puma_status" in stopped*) ;; *) gitwo_die 'Puma may still be running. Run gitwo down and retry.' ;; esac
for state in "$redis_dev" "$redis_test"; do
  case "$state" in stopped|'not allocated') ;; *) gitwo_die 'Redis may still be running or cannot be verified. Run gitwo down and retry.' ;; esac
done
[[ -z "$sidekiq_pids" ]] || gitwo_die 'Sidekiq is still running. Run gitwo down and retry.'

# Validate ownership and local-only DB names BEFORE the Git worktree disappears.
if [[ "$delete_db" == yes ]]; then
  [[ "$GITWO_SERVICES_BACKEND" == native ]] || gitwo_die 'For Compose: volumes are retained; database deletion is not supported by gitwo remove'
  gitwo_need psql; gitwo_need dropdb
  gitwo_db_settings
  marker="$GITWO_STATE/${slug}.db-ready"
  state_file="$(gitwo_state_path "$target")"
  [[ -f "$marker" && ! -L "$marker" && -f "$state_file" && ! -L "$state_file" ]] || gitwo_die 'No safe, registered database ownership metadata; refusing --delete-db'
  gitwo_load_state "$target"
  expected_dev="$(gitwo_expected_db_name "$target" development)"
  expected_test="${expected_dev%_development}_test"
  [[ "$GITWO_DB_DEV" == "$expected_dev" && "$GITWO_DB_TEST" == "$expected_test" ]] || gitwo_die 'Unexpected DB names in state'
  [[ "$(cat "$marker")" == "$expected_dev" ]] || gitwo_die 'DB marker mismatch; refusing purge'
  gitwo_pg psql --no-psqlrc -w -d postgres -Atqc 'SELECT 1' >/dev/null || gitwo_die 'Local PostgreSQL is unreachable'
  printf '  DROP DB:   %s\n             %s\n' "$expected_dev" "$expected_test"
fi

if [[ "$dry_run" == yes ]]; then
  gitwo_ok 'Dry run complete; no data or worktrees changed'
  exit 0
fi

printf 'Type workspace name "%s" to remove its Git worktree: ' "$slug" >&2
IFS= read -r confirmation || gitwo_die 'Confirmation cancelled'
[[ "$confirmation" == "$slug" ]] || gitwo_die 'Workspace name mismatch; nothing removed'
if [[ "$delete_db" == yes ]]; then
  printf 'Type database name "%s" to DROP BOTH workspace databases: ' "$expected_dev" >&2
  IFS= read -r confirmation || gitwo_die 'Database confirmation cancelled'
  [[ "$confirmation" == "$expected_dev" ]] || gitwo_die 'Database name mismatch; nothing removed'
fi
# Never use --force: if anything changed between preflight and removal, Git itself refuses.
# Git may delete ignored files; that is why --delete-ignored is an explicit opt-in above.
git -C "$GITWO_SOURCE" worktree remove "$target" || gitwo_die 'Git refused worktree removal; database was not touched'
gitwo_ok "Removed Git worktree $slug; Git branch preserved"
if [[ "$delete_db" == yes ]]; then
  # Explicitly target localhost and the names verified above. No --force and no remote DBs.
  gitwo_pg dropdb --if-exists --maintenance-db=postgres "$expected_dev" || gitwo_die "Worktree removed, but development DB drop failed; manual recovery required"
  gitwo_pg dropdb --if-exists --maintenance-db=postgres "$expected_test" || gitwo_die "Worktree removed, but test DB drop failed; manual recovery required"
  gitwo_ok 'Both owned local PostgreSQL databases dropped'
fi
# Keep metadata and port counters so old numbering and data provenance remain recoverable.
gitwo_log 'Gitwo .state and runtime ports retained for audit; manual cleanup can follow later.'
