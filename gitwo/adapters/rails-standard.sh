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
  # DATABASE_URL selects ActiveRecord's connection, but does not provide
  # config_for(:database) to application-defined Rake tasks evaluated at load time.
  # Fail before creating any DB rather than inventing or copying a config which
  # could point custom pg_dump/dropdb tasks at the primary checkout's database.
  [[ ! -L config/database.yml ]] || gitwo_die 'Refusing symlinked config/database.yml'
  if gitwo_adapter_custom_database_rake_tasks; then
    [[ -f config/database.yml ]] ||
      gitwo_die "Missing config/database.yml: a custom Rake task calls config_for(:database). Create a workspace-local, ignored database.yml pointing development/test to $GITWO_DB_DEV and $GITWO_DB_TEST. DATABASE_URL alone is not sufficient."
    gitwo_warn 'Custom Rake tasks read config_for(:database) independently of DATABASE_URL. Verify their database target is workspace-isolated before invoking dump/drop tasks.'
  fi
  gitwo_log 'rails-standard uses DATABASE_URL and does not edit config/database.yml'
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
