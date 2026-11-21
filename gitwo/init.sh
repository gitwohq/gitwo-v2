#!/usr/bin/env bash
# Register an existing project worktree and adopt its existing local development DB.
# This script never creates, drops, migrates, seeds, or writes to a PostgreSQL database.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/_common.sh"

usage() { cat >&2 <<'USAGE'
Usage: init.sh [ENG-5160-feature|/absolute/worktree/path] [--adopt-db]

Without --adopt-db, inspect the existing workspace and database.
With --adopt-db, verify the expected isolated local database and Rails tables,
then ask for its exact name before writing a LOCAL Gitwo ownership marker.

No Rails setup, migrations, seeds, DB reset, or external integrations are run.
USAGE
}
selector=''; adopt=no
while [[ $# -gt 0 ]]; do
  case "$1" in
    --adopt-db) adopt=yes ;;
    -h|--help) usage; exit 0 ;;
    --*) gitwo_die "Unknown option: $1" ;;
    *) [[ -z "$selector" ]] || gitwo_die 'Only one worktree selector is allowed'; selector="$1" ;;
  esac
  shift
done

gitwo_need git
gitwo_need ruby
gitwo_need psql
gitwo_check_source
target="$(gitwo_resolve_path "$selector")"
branch="$(git -C "$target" branch --show-current)"
case "$branch" in feature/*|bugfix/*|hotfix/*|experiment/develop-*) ;; *) gitwo_die "Unsupported worktree branch: $branch" ;; esac
type="$(gitwo_branch_type "$branch")"
ticket="$(gitwo_issue_key_from_branch "$branch")"
gitwo_validate_workspace_identity "$target" "$branch"
gitwo_verify_target "$target" "$branch"
# Validate the database first; do not create metadata for an unverified DB.
GITWO_PATH="$target"
gitwo_db_settings
GITWO_DB_DEV="$(gitwo_expected_db_name "$target" development)"
GITWO_DB_TEST="$(gitwo_expected_db_name "$target" test)"

# Validate the exact expected names, not just a project_* prefix.
base="$(basename "$target" | tr '[:lower:]-' '[:lower:]_')"
expected_dev="$(gitwo_expected_db_name "$target" development)"
expected_test="$(gitwo_expected_db_name "$target" test)"
[[ "$GITWO_DB_DEV" == "$expected_dev" && "$GITWO_DB_TEST" == "$expected_test" ]] || gitwo_die 'Workspace state does not match isolated DB naming convention'
[[ "$GITWO_DB_DEV" != "${GITWO_DB_PREFIX}_development" ]] || gitwo_die 'Refusing shared development DB'

source "$GITWO_DIR/_adapter.sh"
if [[ "$GITWO_ADAPTER" == rails-webpack ]]; then
  config="$target/config/database.yml"
  [[ -f "$config" && ! -L "$config" ]] || gitwo_die "Missing or symlinked config/database.yml: $config"
  grep -Fq "database: $GITWO_DB_DEV" "$config" || gitwo_die 'Unexpected development database.yml'
  grep -Fq "database: $GITWO_DB_TEST" "$config" || gitwo_die 'Unexpected test database.yml'
else
  [[ ! -L "$target/config/database.yml" ]] || gitwo_die 'Unsafe symlinked database.yml'
  # For adoption, verify DB identity via Rails' effective connection config too.
  gitwo_ruby_version "$target"
  (cd "$target"; GITWO_EXPECTED_DB="$GITWO_DB_DEV" gitwo_rails development bundle exec rails runner 'abort "Unexpected Rails DB" unless ActiveRecord::Base.connection_db_config.database == ENV.fetch("GITWO_EXPECTED_DB")')
fi

printf 'Gitwo existing-workspace registration\n'
printf '  Worktree: %s\n  Branch:   %s\n  Host:     %s:%s\n  User:     %s\n  DB:       %s\n' \
  "$target" "$branch" "$GITWO_DB_HOST" "$GITWO_DB_PORT" "$GITWO_DB_USER" "$GITWO_DB_DEV"

exists="$(gitwo_pg psql --no-psqlrc -d postgres -Atqc "SELECT 1 FROM pg_database WHERE datname = '$GITWO_DB_DEV'" 2>/dev/null)" || gitwo_die 'Could not query local PostgreSQL; check connection settings'
[[ "$exists" == 1 ]] || gitwo_die "DB does not exist: $GITWO_DB_DEV. Use gitwo setup to create a new DB."
actual="$(gitwo_pg psql --no-psqlrc -d "$GITWO_DB_DEV" -Atqc 'SELECT current_database()' 2>/dev/null)" || gitwo_die "Cannot connect to existing $GITWO_DB_DEV"
[[ "$actual" == "$GITWO_DB_DEV" ]] || gitwo_die "Connected to unexpected DB: $actual"

# Adapter-specific table verification is strictly read-only.
gitwo_adapter_init_tables "$GITWO_DB_DEV"

gitwo_ok 'Existing local database and Rails tables verified (read-only)'
marker="$GITWO_STATE/$(basename "$target").db-ready"
if [[ -e "$marker" || -L "$marker" ]]; then
  [[ -f "$marker" && ! -L "$marker" ]] || gitwo_die "Unsafe marker path: $marker"
  [[ "$(cat "$marker")" == "$GITWO_DB_DEV" ]] || gitwo_die "Existing marker points to a different DB: $marker"
  gitwo_write_state "$target" "$type" "$ticket"
  gitwo_ok "Already registered: $marker"
  exit 0
fi

if [[ "$adopt" != yes ]]; then
  gitwo_warn "Unregistered existing DB. To register without modifying DB: gitwo init --adopt-db"
  exit 2
fi

printf '\n  To register this database, type its EXACT name: %s\n  > ' "$GITWO_DB_DEV" >&2
IFS= read -r confirmation || gitwo_die 'No confirmation received; database unchanged'
[[ "$confirmation" == "$GITWO_DB_DEV" ]] || gitwo_die 'Confirmation mismatch; database unchanged'
gitwo_write_state "$target" "$type" "$ticket"
mkdir -p "$GITWO_STATE"
( umask 077; printf '%s\n' "$GITWO_DB_DEV" > "$marker" )
gitwo_ok "Registered existing DB without modifying PostgreSQL: $marker"
gitwo_log 'You can now run gitwo up or rerun gitwo setup for full dependency/asset verification.'
