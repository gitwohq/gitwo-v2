#!/usr/bin/env bash
# Original legacy Rails Rails adapter, preserved for backwards-compatible upgrades.
gitwo_adapter_validate_repository() {
  [[ -f Gemfile && -f Gemfile.lock && -f package.json && -f config/webpack.config.js ]] || gitwo_die 'legacy Rails adapter expects Gemfile/Gemfile.lock/package.json/Webpack config'
}
gitwo_adapter_prepare_database_config() {
  # This application uses an ignored local database.yml. Avoid tracked modifications.
  if git ls-files --error-unmatch config/database.yml >/dev/null 2>&1; then
    gitwo_die 'config/database.yml is tracked in this branch. Refusing to modify it; use a DATABASE_URL-only setup instead.'
  fi
  [[ ! -L config/database.yml ]] || gitwo_die 'Refusing symlinked database.yml'
  if [[ ! -f config/database.yml ]]; then
    git check-ignore -q config/database.yml || gitwo_die 'config/database.yml is not ignored. Refusing to create an untracked config file.'
    (umask 077; cat > config/database.yml <<YAML
default: &default
  adapter: postgresql
  encoding: unicode
  host: localhost
  port: <%= ENV.fetch("DB_PORT", 5432) %>
  username: <%= ENV.fetch("DB_USERNAME", "${GITWO_DB_USER}") %>
  password: <%= ENV["DB_PASSWORD"] %>
  pool: <%= ENV.fetch("RAILS_MAX_THREADS", 5) %>

development:
  <<: *default
  database: $GITWO_DB_DEV

test:
  <<: *default
  database: $GITWO_DB_TEST

production:
  <<: *default
  database: worktree_production_forbidden
YAML
    )
    gitwo_ok 'Created ignored, isolated config/database.yml'
  fi
  # The file may exist after a resume; abort rather than reusing the develop DB.
  grep -Fq "database: $GITWO_DB_DEV" config/database.yml || gitwo_die 'Development database.yml does not reference isolated workspace DB'
  grep -Fq "database: $GITWO_DB_TEST" config/database.yml || gitwo_die 'Test database.yml does not reference isolated workspace DB'
 }
gitwo_adapter_install_frontend() {
  gitwo_ui_section '03  Frontend / dependencies'
  gitwo_need node; gitwo_need yarn
  gitwo_log 'Checking Node and Yarn'
  node_major="$(node -p 'parseInt(process.versions.node.split(".")[0], 10)')"
  [[ "$node_major" -ge 20 ]] || gitwo_die "Node >=20 required (found $(node -v))"
  yarn_version="$(yarn --version)"
  [[ "$yarn_version" == 1.* ]] || gitwo_die "Yarn Classic 1.x expected (found $yarn_version)"
  gitwo_ui_run 'Yarn install (frozen lockfile)' yarn install --frozen-lockfile --non-interactive
  [[ -x ./node_modules/.bin/webpack ]] || gitwo_die 'Webpack binary missing. Check package.json and yarn installation.'
 }
gitwo_adapter_build_assets() {
  gitwo_ui_section '05  Webpack / assets'
  gitwo_ui_run 'Export JavaScript i18n translations' gitwo_rails development bundle exec i18n export
  if node -e 'process.exit((require("./package.json").scripts || {}).build ? 0 : 1)'; then
    gitwo_ui_run 'Build development assets with Yarn' gitwo_rails development yarn build
  else
    gitwo_warn 'No package.json build script; running Webpack directly'
    gitwo_ui_run 'Build development assets with Webpack' gitwo_rails development ./node_modules/.bin/webpack --config ./config/webpack.config.js
  fi
  gitwo_ui_run 'Build Webpack test packs' env RAILS_ENV=test NODE_ENV=test DATABASE_URL="$(gitwo_db_url "$GITWO_DB_TEST")" \
    DB_HOST="$GITWO_DB_HOST" DB_USERNAME="$GITWO_DB_USER" \
    ./node_modules/.bin/webpack --config ./config/webpack.config.js
  [[ -s public/packs-test/assets-manifest.json ]] || gitwo_die 'Missing public/packs-test/assets-manifest.json after Webpack test build'
 }
gitwo_adapter_assert_database_target() {
  # Checked via exact names in the ignored database.yml created during setup.
  [[ -f config/database.yml && ! -L config/database.yml ]] || gitwo_die 'Missing or symlinked database.yml'
  grep -Fq "database: $GITWO_DB_DEV" config/database.yml || gitwo_die 'Unexpected development DB config'
  grep -Fq "database: $GITWO_DB_TEST" config/database.yml || gitwo_die 'Unexpected test DB config'
}
gitwo_adapter_init_tables() {
  local db="$1" count
  count="$(gitwo_pg psql --no-psqlrc -d "$db" -Atqc "SELECT COUNT(*) FROM pg_catalog.pg_tables WHERE schemaname = 'public' AND tablename IN ('schema_migrations')" 2>/dev/null)" || gitwo_die 'Could not inspect existing legacy Rails tables'
  [[ "$count" == 1 ]] || gitwo_die "Required legacy Rails tables missing ($count/1). Refusing adoption."
}
gitwo_adapter_verify_tests() {
  if [[ "$want_test" == yes ]]; then
    [[ -f spec/lib/import/csv/bills_spec.rb ]] || gitwo_die 'Known focused spec not present in this branch'
    [[ -f spec/acceptance/accounts.feature ]] || gitwo_die 'Known acceptance feature spec not present in this branch'
    gitwo_ui_run 'Focused RSpec: bills_spec.rb' gitwo_rails test bundle exec rspec spec/lib/import/csv/bills_spec.rb
    gitwo_ui_run 'Acceptance: accounts.feature' gitwo_rails test bundle exec rspec spec/acceptance/accounts.feature
  fi
}
