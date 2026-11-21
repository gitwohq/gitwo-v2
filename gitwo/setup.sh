#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/_common.sh"
usage() { cat >&2 <<'USAGE'
Usage: setup.sh [ENG-5303|/absolute/worktree/path] [--db=schema|baseline] [--test] [--seed|--no-seed] [--dump=PATH] [--rebuild-db]
If no workspace is passed, use the current directory.
--db=schema   Create a fresh DB from db/schema.rb or db/structure.sql (default). Seeds run automatically.
--db=baseline Restore a locally prepared PostgreSQL dump (only for a NEW DB).
--test        Run adapter-specific test suite.
--seed        Run unchanged Rails seeds in a NEW development DB (default for schema mode).
--no-seed     Skip seeds for a new schema-based DB.
--dump=PATH   Restore a sanitized pg_dump from the configured dumps directory.
              PATH may identify a file or a dated directory with one archive.
--rebuild-db  Explicitly delete and recreate this managed development DB, then run seeds.
              Requires --seed and typing the exact database name to confirm.
--verbose     Stream full command output to terminal as well as private log.
USAGE
}
want_db=schema; want_db_explicit=no; want_test=no; want_seed=auto; seed_explicit=no; seed_no_seen=no; dump_ref=''; rebuild_db=no; spec=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --db=schema|--db=baseline) want_db="${1#--db=}"; want_db_explicit=yes ;;
    --test) want_test=yes ;;
    --seed) want_seed=yes; seed_explicit=yes ;;
    --no-seed) want_seed=no; seed_no_seen=yes ;;
    --dump=*) dump_ref="${1#--dump=}"; [[ -n "$dump_ref" ]] || gitwo_die 'Missing path for --dump' ;;
    --dump)
      [[ $# -ge 2 ]] || gitwo_die 'Missing path for --dump'
      dump_ref="$2"; shift ;;
    --rebuild-db) rebuild_db=yes ;;
    --verbose) GITWO_VERBOSE=1 ;;
    -h|--help) usage; exit 0 ;;
    --*) gitwo_die "Unknown option: $1" ;;
    *) [[ -z "$spec" ]] || gitwo_die 'Only one worktree selector allowed'; spec="$1" ;;
  esac
  shift
done
[[ "$seed_explicit" == no || "$seed_no_seen" == no ]] || gitwo_die 'Cannot combine --seed and --no-seed'
[[ "$rebuild_db" == no || "$want_seed" == yes ]] || gitwo_die '--rebuild-db requires explicit --seed'
if [[ -n "$dump_ref" ]]; then
  [[ "$want_db_explicit" == no ]] || gitwo_die 'Cannot combine --dump and --db'
  [[ "$want_seed" == auto ]] || gitwo_die 'Cannot combine --dump with --seed/--no-seed'
  [[ "$rebuild_db" == no ]] || gitwo_die 'Cannot combine --dump and --rebuild-db'
  want_db=dump
fi
[[ "$want_db" == schema || "$want_seed" == auto ]] || gitwo_die '--seed/--no-seed are only supported with schema mode'
if [[ "$want_db" == schema && "$want_seed" == auto ]]; then
  case "${GITWO_BOOTSTRAP:-seeds}" in
    schema) want_seed=no ;;
    seeds) want_seed=yes ;;
    *) gitwo_die "Unknown database.bootstrap mode: ${GITWO_BOOTSTRAP}" ;;
  esac
fi
if [[ "$want_db" != schema ]]; then want_seed=no; fi
gitwo_need git; gitwo_need mise; gitwo_need awk; gitwo_need grep; gitwo_need psql; gitwo_need createdb
gitwo_check_source
if [[ "$spec" == /* ]]; then
  target="$spec"
else
  target="$(gitwo_resolve_path "$spec")"
fi
[[ "$target" == "$GITWO_ROOT"/* ]] || gitwo_die 'Only worktrees beside the configured source checkout are supported'
branch="$(git -C "$target" branch --show-current)"
case "$branch" in feature/*|bugfix/*|hotfix/*|experiment/develop-*) ;; *) gitwo_die "Unsupported worktree branch: $branch" ;; esac
type="$(gitwo_branch_type "$branch")"; ticket="$(gitwo_issue_key_from_branch "$branch")"
[[ "$type" == develop ]] || gitwo_validate_ticket "$ticket"
gitwo_validate_workspace_identity "$target" "$branch"
gitwo_verify_target "$target" "$branch"
gitwo_write_state "$target" "$type" "$ticket"
gitwo_db_settings
cd "$target"
source "$GITWO_DIR/_adapter.sh"
gitwo_adapter_validate_repository
gitwo_ruby_version "$target"
gitwo_ui_start "Rails setup" "$ticket"
gitwo_ui_meta "Branch" "$branch"
gitwo_ui_meta "Ruby" "$GITWO_RUBY_VERSION"
gitwo_ui_meta "DB mode" "$want_db"
if [[ "$want_db" == schema ]]; then
  gitwo_ui_meta "Seed new DB" "$want_seed"
elif [[ "$want_db" == dump ]]; then
  source "$GITWO_DIR/_dumps.sh"
  dump_file="$(gitwo_dump_resolve "$dump_ref")"
  gitwo_need pg_restore
  gitwo_ui_meta "Dump" "$dump_file"
fi
gitwo_ui_meta "APP_HOST" "$(gitwo_app_host)"
gitwo_ui_section "01  Configuration"

# Copy only ignored, developer-owned files. Never copy database.yml from develop.
for file in .env .env.local .env.development .env.development.local .env.test config/master.key config/credentials/development.key config/credentials/test.key; do
  if [[ -f "$GITWO_SOURCE/$file" && ! -e "$file" ]] && git check-ignore -q "$file"; then
    mkdir -p "$(dirname "$file")"
    (umask 077; cp "$GITWO_SOURCE/$file" "$file")
    gitwo_ok "Copied ignored local file $file"
  fi
done


gitwo_adapter_prepare_database_config

gitwo_ui_section "02  Ruby / dependencies"
gitwo_ui_run "Ensure Ruby $GITWO_RUBY_VERSION via mise" mise install "ruby@$GITWO_RUBY_VERSION"
gitwo_log 'Matching Bundler to Gemfile.lock'
bundler="$(awk '/^BUNDLED WITH$/ {getline; gsub(/^[[:space:]]+/, ""); print; exit}' Gemfile.lock)"
[[ "$bundler" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || gitwo_die 'Cannot determine locked Bundler version'
if ! mise exec "ruby@$GITWO_RUBY_VERSION" -- gem list --local --exact bundler --version "$bundler" | grep -Fq "bundler ($bundler)"; then
  gitwo_ui_run "Install Bundler $bundler" mise exec "ruby@$GITWO_RUBY_VERSION" -- gem install bundler --version "$bundler" --no-document
fi
if grep -q 'ruby-filemagic' Gemfile.lock; then
  gitwo_need brew
  magic="$(brew --prefix libmagic 2>/dev/null || true)"
  if [[ -z "$magic" || ! -f "$magic/include/magic.h" ]]; then
    gitwo_log 'Installing libmagic (native ruby-filemagic dependency)'
    gitwo_ui_run "Install libmagic" brew install libmagic
    magic="$(brew --prefix libmagic)"
  fi
  mise exec "ruby@$GITWO_RUBY_VERSION" -- bundle config set --local build.ruby-filemagic "--with-magic-dir=$magic"
fi
if ! mise exec "ruby@$GITWO_RUBY_VERSION" -- bundle check >> "$GITWO_LOG_FILE" 2>&1; then
  gitwo_ui_run 'Bundle install (frozen lockfile)' mise exec "ruby@$GITWO_RUBY_VERSION" -- bundle install --frozen
else
  gitwo_ok 'Bundled gems are already installed'
fi

gitwo_adapter_install_frontend
gitwo_adapter_assert_database_target

gitwo_ui_section '04  PostgreSQL / isolated workspace databases'
# Never overwrite a pre-existing DB by default. A marker identifies OUR bootstrapped DB.
gitwo_need pg_restore
[[ "$rebuild_db" == no ]] || gitwo_need dropdb
marker="$GITWO_STATE/$(basename "$target").db-ready"
seed_marker="$GITWO_STATE/$(basename "$target").seed-status"
bootstrap_marker="$GITWO_STATE/$(basename "$target").bootstrap-status"
data_marker="$GITWO_STATE/$(basename "$target").data-source"
db_exists="$(gitwo_pg psql --no-psqlrc -d postgres -Atqc "SELECT 1 FROM pg_database WHERE datname = '$GITWO_DB_DEV'" 2>/dev/null)" || gitwo_die "Cannot connect to local PostgreSQL ($GITWO_DB_HOST:$GITWO_DB_PORT as $GITWO_DB_USER)"
# A failed bootstrap may have left a partially created database. Never adopt it automatically.
if [[ -e "$bootstrap_marker" || -L "$bootstrap_marker" ]]; then
  [[ -f "$bootstrap_marker" && ! -L "$bootstrap_marker" ]] || gitwo_die "Unsafe bootstrap marker: $bootstrap_marker"
  bootstrap_status="$(cat "$bootstrap_marker")"
  case "$bootstrap_status" in
    ready) ;;
    running|failed)
      if [[ -z "$db_exists" && ! -e "$marker" ]]; then
        gitwo_warn 'A previous bootstrap was interrupted before creating the development DB. Retrying safely.'
        rm -f "$bootstrap_marker"
      elif [[ "$rebuild_db" == no ]]; then
        gitwo_die "Incomplete database bootstrap ($bootstrap_status): $GITWO_DB_DEV. Inspect the DB before any explicit rebuild."
      fi
      ;;
    *) gitwo_die "Invalid bootstrap marker: $bootstrap_marker" ;;
  esac
fi
if [[ "$rebuild_db" == yes ]]; then
  [[ "$db_exists" == 1 ]] || gitwo_die "Cannot rebuild missing database $GITWO_DB_DEV; omit --rebuild-db to create it"
  [[ -f "$marker" ]] || gitwo_die "No managed DB marker for $GITWO_DB_DEV. Refusing to drop any unverified database."
  [[ "$GITWO_DB_DEV" == "$(gitwo_expected_db_name "$target" development)" && "$GITWO_DB_DEV" != "${GITWO_DB_PREFIX}_development" ]] || gitwo_die 'Refusing unsafe database name'
  [[ "$(cat "$marker")" == "$GITWO_DB_DEV" ]] || gitwo_die 'Database marker does not match workspace database'
  [[ -t 0 ]] || gitwo_die '--rebuild-db requires an interactive terminal for explicit confirmation'
  gitwo_warn "PERMANENTLY delete all data in local $GITWO_DB_DEV (not the test DB)."
  printf '  Type %s to confirm: ' "$GITWO_DB_DEV" >&2
  IFS= read -r confirmation
  [[ "$confirmation" == "$GITWO_DB_DEV" ]] || gitwo_die 'Confirmation did not match; no databases were deleted'
  gitwo_ui_run "Drop ONLY $GITWO_DB_DEV" gitwo_pg dropdb "$GITWO_DB_DEV"
  rm -f "$marker" "$seed_marker" "$bootstrap_marker" "$data_marker"
  db_exists=''
fi
if [[ "$db_exists" == 1 ]]; then
  [[ -f "$marker" ]] || gitwo_die "DB $GITWO_DB_DEV already exists but has no workspace marker. Refusing to overwrite it. Inspect manually."
  if [[ -f "$seed_marker" ]]; then
    case "$(cat "$seed_marker")" in
      ready) gitwo_ok 'Development seeds were completed previously' ;;
      running|failed) gitwo_die "Previous seeding of $GITWO_DB_DEV was interrupted or failed. DB is partially populated; run setup --rebuild-db --seed with explicit confirmation if safe." ;;
      *) gitwo_die "Invalid seed status marker: $seed_marker" ;;
    esac
  fi
  if [[ "$want_db" == dump || "$want_db" == baseline ]]; then
    gitwo_die "Database $GITWO_DB_DEV already exists; refusing to restore over it. Use a NEW workspace or explicitly rebuild after reviewing data."
  fi
  if [[ "$want_seed" == yes && "$seed_explicit" == yes ]]; then
    gitwo_die "Database $GITWO_DB_DEV already exists. Seeds are not idempotent; only seed a new database or use --rebuild-db --seed with confirmation."
  fi
  gitwo_ok "Reusing existing $GITWO_DB_DEV"
else
  # Retain a failed marker on interruption, including during schema load or migrations.
  (umask 077; printf 'running\n' > "$bootstrap_marker")
  trap 'result=$?; if [[ "$result" -ne 0 ]]; then (umask 077; printf "failed\n" > "$bootstrap_marker"); fi' EXIT
  gitwo_log "Creating isolated DB $GITWO_DB_DEV"
  gitwo_ui_run "Create $GITWO_DB_DEV" gitwo_pg createdb --encoding=UTF8 "$GITWO_DB_DEV"
  if [[ "$want_db" == baseline || "$want_db" == dump ]]; then
    if [[ "$want_db" == dump ]]; then
      dump="$dump_file"
    else
      dump="$GITWO_STATE/baseline.dump"
      [[ -f "$dump" ]] || gitwo_die "Missing baseline snapshot: $dump. Run baseline.sh first."
    fi
    gitwo_ui_run "Restore PostgreSQL archive" gitwo_pg pg_restore --no-owner --no-acl --exit-on-error --single-transaction --dbname "$GITWO_DB_DEV" "$dump"
    # Existing snapshot tables are versioned; migration is normally safe here.
    gitwo_ui_run 'Apply Rails migrations' gitwo_rails development bundle exec rails db:migrate
  else
    [[ -f db/schema.rb || -f db/structure.sql ]] || gitwo_die 'No Rails schema snapshot found; cannot bootstrap 677 historical migrations safely'
    gitwo_ui_run 'Load Rails schema' gitwo_rails development bundle exec rails db:schema:load
  fi
  (umask 077; printf '%s\n' "$GITWO_DB_DEV" > "$marker")
  gitwo_ok "Database initialized: $GITWO_DB_DEV"
fi
gitwo_ui_run 'Prepare isolated RSpec database' gitwo_rails test bundle exec rails db:prepare


gitwo_adapter_build_assets

gitwo_ui_section '06  Rails / verification'
gitwo_ui_run 'Verify Rails boot' gitwo_rails development bundle exec rails runner 'puts "Rails #{Rails.version}, Ruby #{RUBY_VERSION}"'
if [[ "$want_seed" == yes && "$db_exists" != 1 ]]; then
  (umask 077; printf 'running\n' > "$seed_marker")
  gitwo_warn 'Executing unchanged db/seeds.rb once in the new development DB. This may enqueue mail/jobs.'
  if gitwo_ui_run 'Seed development database' gitwo_rails development bundle exec rails db:seed; then
    (umask 077; printf 'ready\n' > "$seed_marker")
  else
    (umask 077; printf 'failed\n' > "$seed_marker")
    gitwo_die "Seeding failed. This DB may be partially populated. Do not rerun seeds; use --rebuild-db --seed only if data loss is acceptable."
  fi
fi

gitwo_adapter_verify_tests
if [[ "$db_exists" != 1 ]]; then
  # Record provenance only after successful setup. This is metadata, not a data audit.
  if [[ "$want_db" == dump ]]; then
    data_source="dump:${dump_file#"$GITWO_ROOT/$GITWO_DUMPS_DIR/"}"
  elif [[ "$want_db" == baseline ]]; then
    data_source=baseline
  elif [[ "$want_seed" == yes ]]; then
    data_source=seeded
  else
    data_source=schema-only
  fi
  (umask 077; printf '%s\n' "$data_source" > "$data_marker")
  (umask 077; printf 'ready\n' > "$bootstrap_marker")
  trap - EXIT
fi
gitwo_ui_note_warnings
gitwo_ui_done "Setup completed: $target"
gitwo_ui_meta "Git changes" "$(git status --short | wc -l | tr -d ' ') tracked/untracked entries (review if nonzero)"
