#!/usr/bin/env bash
# Opt-in conventional Rails adapter. Never modifies tracked Rails files.
source "$GITWO_DIR/_testing.sh"
gitwo_adapter_validate_repository() {
  [[ -f Gemfile && -f Gemfile.lock && -f config/application.rb ]] || gitwo_die 'rails-standard needs Gemfile, Gemfile.lock and config/application.rb'
  [[ -f db/schema.rb || -f db/structure.sql ]] || gitwo_die 'rails-standard requires a committed Rails schema snapshot'
}
gitwo_adapter_custom_database_rake_tasks() {
  [[ -d lib/tasks ]] &&
    grep -REq 'config_for[[:space:]]*\([[:space:]]*:database[[:space:]]*\)' lib/tasks
}
gitwo_adapter_prepare_database_config() {
  # Rails uses DATABASE_URL for ActiveRecord, but custom Rake tasks can read
  # config_for(:database) independently. Only adapt an IGNORED workspace file.
  # A tracked database.yml is never modified by workspace provisioning.
  [[ ! -L config/database.yml ]] || gitwo_die 'Refusing symlinked config/database.yml'
  if [[ -n "${GITWO_SOURCE:-}" ]] &&
     ! git -C "$GITWO_SOURCE" ls-files --error-unmatch -- config/database.yml >/dev/null 2>&1 &&
     git -C "$GITWO_SOURCE" check-ignore -q -- config/database.yml; then
    if [[ ! -e config/database.yml ]]; then
      [[ -d config && ! -L config ]] || gitwo_die 'Unsafe workspace config directory'
      (umask 077; set -C; cat > config/database.yml <<YAML
default: &default
  adapter: postgresql
  encoding: unicode
  host: <%= ENV.fetch("PGHOST", "localhost") %>
  port: <%= ENV.fetch("PGPORT", 5432) %>
  username: <%= ENV.fetch("PGUSER", ENV.fetch("USER", "postgres")) %>
development:
  <<: *default
  database: <%= ENV.fetch("GITWO_DB_DEV", "$GITWO_DB_DEV") %>
test:
  <<: *default
  database: <%= ENV.fetch("GITWO_DB_TEST", "$GITWO_DB_TEST") %>
YAML
      ) || gitwo_die 'Could not create ignored workspace database.yml'
      gitwo_ok 'Created isolated, ignored workspace database.yml'
    else
      [[ -f config/database.yml ]] || gitwo_die 'Unsafe workspace database.yml'
    fi
    ruby "$GITWO_DIR/rails-config.rb" workspace config/database.yml "$GITWO_DB_DEV" "$GITWO_DB_TEST" ||
      gitwo_die 'Could not safely adapt ignored database.yml; inspect the existing configuration'
  fi
  if gitwo_adapter_custom_database_rake_tasks; then
    [[ -f config/database.yml ]] ||
      gitwo_die "Missing config/database.yml: custom Rake task calls config_for(:database). Provide isolated development/test config before setup."
    gitwo_warn 'Custom Rake tasks read config_for(:database) independently of DATABASE_URL. Both database targets are verified before bootstrapping.'
  fi
  gitwo_log 'rails-standard uses DATABASE_URL; tracked config/database.yml remains unchanged'
}
gitwo_adapter_install_frontend() {
  if [[ -f package.json && -f yarn.lock ]]; then
    gitwo_need node; gitwo_need yarn
    gitwo_ui_section '03  Frontend / Yarn'
    gitwo_ui_run 'Yarn install (frozen lockfile)' yarn install --frozen-lockfile --non-interactive
  else
    gitwo_log 'No Yarn lockfile: skipping frontend dependency install'
  fi
}
gitwo_adapter_assert_database_target() {
  # Verify Rails' effective ActiveRecord connection BEFORE any DB mutation.
  # A custom Rake task that uses config_for(:database) bypasses DATABASE_URL;
  # ensure its independent target is isolated for BOTH development and test.
  local development_check test_check rake_check=''
  development_check='abort "Unexpected Rails development database" unless ActiveRecord::Base.connection_db_config.database == ENV.fetch("GITWO_EXPECTED_DB")'
  test_check='abort "Unexpected Rails test database" unless ActiveRecord::Base.connection_db_config.database == ENV.fetch("GITWO_EXPECTED_DB")'
  if gitwo_adapter_custom_database_rake_tasks; then
    rake_check='; db = Rails.application.config_for(:database); abort "Custom Rake config_for(:database) must use isolated workspace database" unless db && db.fetch(:database, nil).to_s == ENV.fetch("GITWO_EXPECTED_DB")'
  fi
  GITWO_EXPECTED_DB="$GITWO_DB_DEV" gitwo_rails development bundle exec rails runner "${development_check}${rake_check}" >/dev/null || gitwo_die 'rails-standard development DB target verification failed'
  GITWO_EXPECTED_DB="$GITWO_DB_TEST" gitwo_rails test bundle exec rails runner "${test_check}${rake_check}" >/dev/null || gitwo_die 'rails-standard test DB target verification failed'
}


# This is the final readiness gate, after schema, test preparation and seeds.
# Verify actual PostgreSQL connections rather than merely checking Rails YAML.
gitwo_adapter_verify_ready_databases() {
  [[ "$GITWO_DB_DEV" != "$GITWO_DB_TEST" ]] ||
    gitwo_die 'Development and test database names overlap'
  [[ "$GITWO_DB_DEV" == "$(gitwo_expected_db_name "$GITWO_PATH" development)" ]] ||
    gitwo_die 'Unexpected development database identity'
  [[ "$GITWO_DB_TEST" == "$(gitwo_expected_db_name "$GITWO_PATH" test)" ]] ||
    gitwo_die 'Unexpected test database identity'

  local env_name expected actual rails_check
  for env_name in development test; do
    if [[ "$env_name" == development ]]; then expected="$GITWO_DB_DEV"; else expected="$GITWO_DB_TEST"; fi
    actual="$(gitwo_pg psql --no-psqlrc -d "$expected" -Atqc 'SELECT current_database()' 2>/dev/null)" ||
      gitwo_die "Isolated $env_name database is missing or inaccessible: $expected"
    [[ "$actual" == "$expected" ]] ||
      gitwo_die "PostgreSQL $env_name target mismatch: expected $expected; got $actual"

    rails_check='db = ActiveRecord::Base.connection; actual = db.select_value("SELECT current_database()"); abort "Rails connected to unexpected database: #{actual}" unless actual == ENV.fetch("GITWO_EXPECTED_DB")'
    GITWO_EXPECTED_DB="$expected" gitwo_rails "$env_name" bundle exec rails runner "$rails_check" >/dev/null ||
      gitwo_die "Rails $env_name runtime did not connect to isolated database $expected"
  done
  gitwo_adapter_assert_database_target
  gitwo_ok "Verified isolated Rails development and test databases: $GITWO_DB_DEV / $GITWO_DB_TEST"
}

gitwo_adapter_build_assets() {
  # The standard adapter avoids Webpack and app-specific i18n tasks.
  gitwo_log 'rails-standard: no application-specific asset build requested'
}
gitwo_adapter_init_tables() {
  local db="$1" count
  count="$(gitwo_pg psql --no-psqlrc -d "$db" -Atqc "SELECT COUNT(*) FROM pg_catalog.pg_tables WHERE schemaname = 'public' AND tablename = 'schema_migrations'" 2>/dev/null)" || gitwo_die 'Could not inspect Rails schema_migrations'
  [[ "$count" == 1 ]] || gitwo_die 'Rails schema_migrations is missing; refusing adoption'
}
gitwo_adapter_verify_tests() {
  if [[ "$want_test" == yes ]]; then
    gitwo_ui_run 'Run Rails test suite' gitwo_test_run test
  fi
}
