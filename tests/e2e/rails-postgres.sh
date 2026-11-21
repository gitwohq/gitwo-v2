#!/usr/bin/env bash
# Exercise Gitwo with a freshly generated Rails application and a real local PostgreSQL service.
# This fixture does not require a third-party issue tracker or any production credentials.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
work="$(mktemp -d "${RUNNER_TEMP:-/tmp}/gitwo-rails-e2e.XXXXXXXX")"
app="$work/demo_app"
remote="$work/demo.git"
install_prefix="$work/gitwo-install"
server_pid=''

cleanup() {
  if [[ -n "$server_pid" ]]; then
    "$install_prefix/bin/gitwo" down develop-1 >/dev/null 2>&1 || true
    kill "$server_pid" >/dev/null 2>&1 || true
    wait "$server_pid" >/dev/null 2>&1 || true
  fi
  if [[ "${GITWO_KEEP_E2E:-0}" != 1 ]]; then rm -rf -- "$work"; else echo "Fixture retained at $work"; fi
}
trap cleanup EXIT

command -v mise >/dev/null || { echo 'Missing mise' >&2; exit 2; }
command -v psql >/dev/null || { echo 'Missing PostgreSQL client' >&2; exit 2; }
command -v redis-server >/dev/null || { echo 'Missing Redis server' >&2; exit 2; }
pg_isready -h "${PGHOST:-127.0.0.1}" -U "${PGUSER:?}" -d postgres

# A real Rails installation is required: do not mock ActiveRecord, Bundler or Puma.
gem install rails --version '7.2.4' --no-document
rails _7.2.4_ new "$app" --database=postgresql --skip-git --skip-bundle \
  --skip-javascript --skip-hotwire --skip-jbuilder --skip-system-test \
  --skip-docker --skip-kamal > "$work/rails-new.log"
cd "$app"
# Keep the Ruby version identical for ruby/setup-ruby and mise.
printf '3.3.14\n' > .ruby-version
# Test standard RSpec and Rails Minitest commands without Gitwo's run wrapper.
cat >> Gemfile <<'RUBY'
group :test do
  gem 'rspec-rails', '~> 7.1'
end
RUBY
# Native commands require a one-time, environment-aware Rails database config.
# Gitwo must never rewrite an application's tracked database.yml itself.
ruby <<'RUBY'
path = 'config/database.yml'
text = File.read(path)
{
  'demo_app_development' => '<%= ENV.fetch("GITWO_DB_DEV", "demo_app_development") %>',
  'demo_app_test' => '<%= ENV.fetch("GITWO_DB_TEST", "demo_app_test") %>'
}.each do |old, value|
  pattern = /^(\s*database: )#{Regexp.escape(old)}(\s*)$/
  abort "Missing Rails database.yml entry: #{old}" unless text.match?(pattern)
  text.sub!(pattern, "\\1#{value}\\2")
end
File.write(path, text)
RUBY
bundle install --quiet

mkdir -p db/migrate app/models
cat > db/migrate/20261121000000_create_widgets.rb <<'RUBY'
class CreateWidgets < ActiveRecord::Migration[7.2]
  def change
    create_table :widgets do |table|
      table.string :name, null: false
      table.timestamps
    end
  end
end
RUBY
cat > app/models/widget.rb <<'RUBY'
class Widget < ApplicationRecord
end
RUBY
cat > db/seeds.rb <<'RUBY'
Widget.create!(name: 'gitwo-e2e-seeded')
RUBY
cat > config/routes.rb <<'RUBY'
Rails.application.routes.draw do
  root to: proc { |_env| [200, { 'Content-Type' => 'text/plain' }, ['gitwo-e2e-ok']] }
end
RUBY
export DATABASE_URL="postgresql://${PGUSER}:${PGPASSWORD}@${PGHOST:-127.0.0.1}:${PGPORT:-5432}/gitwo_fixture_development"
bundle exec rails db:prepare > "$work/fixture-db.log"

# Use a real local bare remote, making origin/main usable without remote network access.
git init -q -b main
git config user.email ci@example.invalid
git config user.name 'Gitwo CI'
git add .
git commit -qm 'Create Rails E2E fixture'
git init -q --bare "$remote"
git remote add origin "$remote"
git push -q -u origin main

bash "$repo_root/install.sh" "$install_prefix" > "$work/install.log"
export GITWO_PROJECT_ROOT="$app"
export GITWO_DB_PREFIX=gitwo_fixture
export GITWO_PROXY="${GITWO_E2E_PROXY:-none}"
export GITWO_DB_USER="${PGUSER}"
export GITWO_BOOTSTRAP=schema
cli="$install_prefix/bin/gitwo"
"$cli" detect --project="$app" --json > "$work/detection.json"
"$cli" init --project="$app" --yes > "$work/init.log"
"$cli" config validate

# Exercise schema load, seed once, and isolated test DB creation.
first="$($cli new develop --seed)"
[[ "$(basename "$first")" == 'develop-1' ]]
# Gitwo generated an untracked .envrc only after verifying both native DBs.
[[ -f "$first/.envrc" ]]
[[ -z "$(git -C "$first" status --porcelain --untracked-files=all)" ]]
command -v direnv >/dev/null || { echo 'direnv missing in integration job' >&2; exit 2; }
direnv allow "$first" >/dev/null
# The caller deliberately has a development DATABASE_URL. direnv must remove
# it before running any test command and restore it when leaving the workspace.
fixture_database_url="$DATABASE_URL"
cd "$first"
eval "$(direnv export bash)"
[[ "${GITWO_WORKSPACE:-}" == develop-1 ]]
[[ ! ${DATABASE_URL+x} && ! ${RAILS_ENV+x} && ! ${REDIS_URL+x} ]]
[[ "$GITWO_DB_DEV" == gitwo_fixture_develop_1_development ]]
[[ "$GITWO_DB_TEST" == gitwo_fixture_develop_1_test ]]
# Direct Rails development commands must not use the main checkout DB.
bin/rails runner 'abort unless ActiveRecord::Base.connection_db_config.database == "gitwo_fixture_develop_1_development"' > "$work/native-dev.log"
mkdir -p spec
cat > spec/rails_helper.rb <<'RUBY'
ENV['RAILS_ENV'] = 'test'
require_relative '../config/environment'
require 'rspec/rails'
RUBY
cat > spec/gitwo_native_spec.rb <<'RUBY'
require 'rails_helper'
RSpec.describe 'Gitwo native RSpec isolation' do
  it 'uses the selected workspace test database' do
    expect(ActiveRecord::Base.connection_db_config.database).to eq('gitwo_fixture_develop_1_test')
    expect(Widget.create!(name: 'gitwo-rspec').persisted?).to be(true)
  end
end
RUBY
bundle exec rspec spec/gitwo_native_spec.rb > "$work/native-rspec.log"
# Minitest likewise uses its own test database without a Gitwo wrapper.
mkdir -p test/models
cat > test/models/gitwo_native_test.rb <<'RUBY'
require 'test_helper'
class GitwoNativeTest < ActiveSupport::TestCase
  test 'workspace test database' do
    assert_equal 'gitwo_fixture_develop_1_test', ActiveRecord::Base.connection_db_config.database
    assert Widget.create!(name: 'gitwo-minitest-native').persisted?
  end
end
RUBY
bin/rails test test/models/gitwo_native_test.rb > "$work/native-minitest.log"
cd "$app"
eval "$(direnv export bash)"
[[ "${DATABASE_URL:-}" == "$fixture_database_url" ]]
[[ ! ${GITWO_WORKSPACE+x} ]]
# The generated Rails app uses Minitest. Ensure the CLI selects the isolated
# test DB for both the explicit and auto-detected test commands.
mkdir -p "$first/test/models"
cat > "$first/test/models/gitwo_fixture_test.rb" <<'RUBY'
require "test_helper"

class GitwoFixtureTest < ActiveSupport::TestCase
  test "isolated workspace test database" do
    assert_equal "gitwo_fixture_develop_1_test", ActiveRecord::Base.connection_db_config.database
    assert Widget.create!(name: "gitwo-minitest").persisted?
  end
end
RUBY
"$cli" run develop-1 minitest test/models/gitwo_fixture_test.rb > "$work/minitest.log"
"$cli" run develop-1 test test/models/gitwo_fixture_test.rb > "$work/test-auto.log"
"$cli" status develop-1 --json > "$work/status-1.json"
ruby -rjson -e 'x=JSON.parse(File.read(ARGV.fetch(0))); abort x.inspect unless x["data_source"] == "seeded"' "$work/status-1.json"
[[ "$(psql -d gitwo_fixture_develop_1_development -Atqc "SELECT COUNT(*) FROM widgets WHERE name='gitwo-e2e-seeded'")" == 1 ]]

archive="$($cli dump create develop-1 --name=e2e-snapshot)"
[[ -s "$archive" ]]
"$cli" dump inspect "$archive" > "$work/inspect.log"
second="$($cli new develop --dump="$archive")"
[[ "$(basename "$second")" == 'develop-2' ]]
[[ -f "$second/.envrc" ]]
direnv allow "$second" >/dev/null
cd "$second"
eval "$(direnv export bash)"
[[ "${GITWO_WORKSPACE:-}" == develop-2 ]]
[[ "$GITWO_DB_DEV" == gitwo_fixture_develop_2_development ]]
[[ "$GITWO_DB_TEST" == gitwo_fixture_develop_2_test ]]
bin/rails runner 'abort unless ActiveRecord::Base.connection_db_config.database == "gitwo_fixture_develop_2_development"' > "$work/native-second.log"
cd "$app"
eval "$(direnv export bash)"
[[ "${DATABASE_URL:-}" == "$fixture_database_url" ]]
[[ "$(psql -d gitwo_fixture_develop_2_development -Atqc "SELECT COUNT(*) FROM widgets WHERE name='gitwo-e2e-seeded'")" == 1 ]]

# Running two workspaces must never change their permanent source checkout.
[[ "$(git -C "$app" branch --show-current)" == main ]]
[[ "$(git -C "$first" branch --show-current)" == experiment/develop-1 ]]
[[ "$(git -C "$second" branch --show-current)" == experiment/develop-2 ]]

"$cli" up develop-1 > "$work/server.log" 2>&1 &
server_pid="$!"
ports_file="$(find "${HOME}/.local/state/gitwo/projects" -name 'develop-1.ports' -print -quit)"
# Runtime ports are created asynchronously after the server starts.
# In Portless mode, the allocated direct port differs from the proxy-assigned
# backend port. Verify the real HTTPS route AND its CA instead of using -k.
healthy=no
for ((attempt=0; attempt<120; attempt++)); do
  if [[ "$GITWO_PROXY" == portless ]]; then
    url="$($cli open develop-1 --print)"
    if [[ -f "$HOME/.portless/ca.pem" ]] &&
       curl --fail --silent --max-time 2 --cacert "$HOME/.portless/ca.pem" "$url/" | grep -qx 'gitwo-e2e-ok'; then
      healthy=yes; break
    fi
  else
    ports_file="$(find "${HOME}/.local/state/gitwo/projects" -name 'develop-1.ports' -print -quit)"
    if [[ -f "$ports_file" ]]; then
      port="$(awk -F= '$1=="WEB_PORT" {print $2}' "$ports_file")"
      if [[ -n "$port" ]] && curl --fail --silent --max-time 2 "http://127.0.0.1:${port}/" | grep -qx 'gitwo-e2e-ok'; then
        healthy=yes; break
      fi
    fi
  fi
  if ! kill -0 "$server_pid" 2>/dev/null; then
    echo 'Puma failed during bootstrap' >&2
    cat "$work/server.log" >&2
    exit 1
  fi
  sleep 1
done
[[ "$healthy" == yes ]] || { echo 'Rails did not become healthy' >&2; cat "$work/server.log" >&2; exit 1; }
"$cli" status develop-1 --check-http > "$work/health-status.log"
"$cli" down develop-1
"$cli" remove develop-2 --dry-run > "$work/remove-dry-run.log" 2>&1 || true
printf '[PASS] real Rails+PostgreSQL+Redis E2E: two worktrees, native RSpec/Minitest, direnv isolation, seeds, dump/restore, Puma, HTTP, down\n'
