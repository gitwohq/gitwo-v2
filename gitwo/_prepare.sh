#!/usr/bin/env bash
# Preflight for `gitwo up`. All metadata is local. Never alter an existing DB.
# This file is sourced by run.sh after _common.sh.

gitwo_up_prepare() {
  local target="$1" branch type ticket slug safe_name expected_dev expected_test
  local state_file marker db_exists actual_state actual_marker

  branch="$(git -C "$target" branch --show-current)" || gitwo_die "Cannot inspect Git branch: $target"
  case "$branch" in
    feature/*|bugfix/*|hotfix/*|experiment/develop-*) ;;
    *) gitwo_die "Unsupported worktree branch: $branch" ;;
  esac
  type="$(gitwo_branch_type "$branch")"
  ticket="$(gitwo_issue_key_from_branch "$branch")"
  gitwo_verify_target "$target" "$branch"

  slug="$(basename "$target")"
  gitwo_validate_workspace_identity "$target" "$branch"
  GITWO_PATH="$target"
  gitwo_compose_up "$target"

  expected_dev="$(gitwo_expected_db_name "$target" development)"
  expected_test="$(gitwo_expected_db_name "$target" test)"
  state_file="$(gitwo_state_path "$target")"
  marker="$GITWO_STATE/${slug}.db-ready"

  # Validate existing metadata even when no bootstrap is needed.
  if [[ -e "$state_file" || -L "$state_file" ]]; then
    [[ -f "$state_file" && ! -L "$state_file" ]] || gitwo_die "Unsafe workspace state path: $state_file"
    gitwo_load_state "$target"
    [[ "$GITWO_DB_DEV" == "$expected_dev" && "$GITWO_DB_TEST" == "$expected_test" ]] || gitwo_die "Workspace state references an unexpected database: $GITWO_DB_DEV"
  fi
  if [[ -e "$marker" || -L "$marker" ]]; then
    [[ -f "$marker" && ! -L "$marker" ]] || gitwo_die "Unsafe database marker: $marker"
    actual_marker="$(cat "$marker")"
    [[ "$actual_marker" == "$expected_dev" ]] || gitwo_die "Database marker references unexpected DB: $actual_marker"
  fi

  # Always check existence, even for a previously registered workspace.
  # A missing DB must never be silently recreated when ownership metadata exists.
  gitwo_need psql
  gitwo_db_settings
  db_exists="$(gitwo_pg psql --no-psqlrc -d postgres -Atqc "SELECT 1 FROM pg_database WHERE datname = '$expected_dev'" 2>/dev/null)" \
    || gitwo_die "Cannot inspect local PostgreSQL ($GITWO_DB_HOST:$GITWO_DB_PORT). Nothing was changed."
  local bootstrap_status="$GITWO_STATE/${slug}.bootstrap-status"
  if [[ -e "$bootstrap_status" || -L "$bootstrap_status" ]]; then
    [[ -f "$bootstrap_status" && ! -L "$bootstrap_status" ]] || gitwo_die "Unsafe bootstrap marker: $bootstrap_status"
    case "$(cat "$bootstrap_status")" in
      ready) ;;
      running|failed) gitwo_die "Incomplete database bootstrap: $expected_dev. Refusing automatic adoption or startup; inspect the DB and explicit recovery options." ;;
      *) gitwo_die "Invalid bootstrap status marker: $bootstrap_status" ;;
    esac
  fi
  local seed_status="$GITWO_STATE/${slug}.seed-status"
  if [[ -f "$seed_status" ]]; then
    [[ ! -L "$seed_status" ]] || gitwo_die "Unsafe seed status marker: $seed_status"
    case "$(cat "$seed_status")" in
      ready) ;; 
      running|failed) gitwo_die "Previous seeding failed or was interrupted for $expected_dev. Refusing to start a partially seeded workspace; inspect and explicitly rebuild if appropriate." ;;
      *) gitwo_die "Unexpected seed marker content: $seed_status" ;;
    esac
  fi
  if [[ -f "$state_file" && -f "$marker" ]]; then
    gitwo_up_check_database_config "$target" "$expected_dev" "$expected_test"
    [[ "$db_exists" == 1 ]] || gitwo_die "Registered DB $expected_dev is missing. Refusing to recreate it automatically."
    return 0
  fi

  gitwo_warn "Workspace $(basename "$target") has incomplete Gitwo metadata; checking its existing DB"
  if [[ "$db_exists" == 1 ]]; then
    # init.sh validates database.yml, the connected database and core Rails tables.
    # When unregistered, it asks the user to type the exact DB name.
    if [[ ! -f "$marker" ]]; then
      gitwo_warn "Existing database $expected_dev is unregistered. Adoption needs explicit confirmation."
      "$GITWO_DIR/init.sh" "$target" --adopt-db
    else
      gitwo_log 'Database is registered; regenerating missing workspace metadata (no Rails setup)'
      "$GITWO_DIR/init.sh" "$target"
    fi
  elif [[ -z "$db_exists" ]]; then
    [[ ! -e "$marker" ]] || gitwo_die "Database $expected_dev is missing, but its ownership marker exists. Refusing to recreate it automatically."
    gitwo_log "No database $expected_dev found. Running Rails setup (schema + default seeds)."
    "$GITWO_DIR/setup.sh" "$target"
  else
    gitwo_die "Unexpected PostgreSQL response while checking $expected_dev: $db_exists"
  fi

  [[ -f "$state_file" && -f "$marker" ]] || gitwo_die 'Workspace initialization did not create the required state and DB marker'
  gitwo_load_state "$target"
  [[ "$GITWO_DB_DEV" == "$expected_dev" && "$GITWO_DB_TEST" == "$expected_test" ]] || gitwo_die 'Unexpected DB in generated workspace state'
  [[ "$(cat "$marker")" == "$expected_dev" ]] || gitwo_die 'Generated database marker does not match the workspace'
  gitwo_up_check_database_config "$target" "$expected_dev" "$expected_test"
  gitwo_ok "Workspace ready: $(basename "$target")"
}

gitwo_up_check_database_config() {
  local target="$1" development="$2" test="$3" config
  if [[ "$GITWO_ADAPTER" == rails-standard ]]; then
    # The standard adapter never modifies tracked database.yml.
    [[ ! -L "$target/config/database.yml" ]] || gitwo_die 'Unsafe symlinked database.yml'
    gitwo_ruby_version "$target"
    (cd "$target"; source "$GITWO_DIR/_adapter.sh"; GITWO_DB_DEV="$development" GITWO_DB_TEST="$test" gitwo_adapter_assert_database_target)
    return
  fi
  config="$target/config/database.yml"
  [[ -f "$config" && ! -L "$config" ]] || gitwo_die "Missing or symlinked database.yml: $config"
  grep -Fq "database: $development" "$config" || gitwo_die "database.yml does not contain isolated development DB: $development"
  grep -Fq "database: $test" "$config" || gitwo_die "database.yml does not contain isolated test DB: $test"
}
