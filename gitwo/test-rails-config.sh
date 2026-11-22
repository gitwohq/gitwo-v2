#!/usr/bin/env bash
# Verify the opt-in Rails database.yml integration without evaluating Rails code.
set -euo pipefail
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
work="$(mktemp -d "${TMPDIR:-/tmp}/gitwo-db-config.XXXXXXXX")"
trap 'rm -rf -- "$work"' EXIT
cat > "$work/database.yml" <<'YAML'
default: &default
  adapter: postgresql
  pool: <%= ENV.fetch("RAILS_MAX_THREADS") { 5 } %>

development:
  <<: *default
  database: my_app_development

test:
  <<: *default
  database: my_app_test

production:
  <<: *default
  database: my_app_production
YAML
cp "$work/database.yml" "$work/original"
ruby "$here/rails-config.rb" plan "$work/database.yml" > "$work/plan"
cmp "$work/database.yml" "$work/original"
grep -q 'GITWO_DB_DEV' "$work/plan"
grep -q 'GITWO_DB_TEST' "$work/plan"
ruby "$here/rails-config.rb" apply "$work/database.yml" "$work/backups" >/dev/null
test "$(find "$work/backups" -type f | wc -l | tr -d ' ')" == 1
cmp "$work/original" "$work"/backups/*.yml
grep -Fq 'database: <%= ENV.fetch("GITWO_DB_DEV", "my_app_development") %>' "$work/database.yml"
grep -Fq 'database: <%= ENV.fetch("GITWO_DB_TEST", "my_app_test") %>' "$work/database.yml"
grep -q 'my_app_production' "$work/database.yml"
ruby "$here/rails-config.rb" plan "$work/database.yml" | grep -q 'already uses'
# Existing ERB, URL configurations, nested DBs, and symlinks must not be rewritten.
for input in 'url: postgresql://localhost/shared' 'database: <%= ENV.fetch("DB_NAME") %>' 'primary:'; do
  cp "$work/original" "$work/reject.yml"
  if [[ "$input" == primary: ]]; then
    ruby - "$work/reject.yml" <<'RUBY'
path = ARGV.fetch(0)
File.write(path, File.read(path).sub('  database: my_app_test', "  primary:\n    database: my_app_test"))
RUBY
  else
    sed "s|  database: my_app_test|  $input|" "$work/original" > "$work/reject.yml"
  fi
  cp "$work/reject.yml" "$work/reject-original"
  if ruby "$here/rails-config.rb" apply "$work/reject.yml" "$work/backups" > "$work/output" 2>&1; then
    echo "Expected unsafe config rejection: $input" >&2; exit 1
  fi
  cmp "$work/reject.yml" "$work/reject-original"
done
ln -s "$work/original" "$work/symlink.yml"
if ruby "$here/rails-config.rb" plan "$work/symlink.yml" >"$work/output" 2>&1; then
  echo 'Expected symlink refusal' >&2; exit 1
fi
# A workspace-local ignored file can be specialized without touching the source.
cp "$work/original" "$work/workspace.yml"
ruby "$here/rails-config.rb" workspace "$work/workspace.yml" feature_1_development feature_1_test >/dev/null
grep -Fq 'ENV.fetch("GITWO_DB_DEV", "feature_1_development")' "$work/workspace.yml"
grep -Fq 'ENV.fetch("GITWO_DB_TEST", "feature_1_test")' "$work/workspace.yml"
ruby "$here/rails-config.rb" workspace "$work/workspace.yml" feature_1_development feature_1_test >/dev/null
cp "$work/workspace.yml" "$work/stable"
cmp "$work/stable" "$work/workspace.yml"
if ruby "$here/rails-config.rb" workspace "$work/workspace.yml" shared_database shared_database > "$work/error" 2>&1; then
  echo 'Workspace mode allowed overlapping DBs' >&2; exit 1
fi
cmp "$work/stable" "$work/workspace.yml"
if ruby "$here/rails-config.rb" workspace "$work/reject-original" unsafe/dev safe_test > "$work/error" 2>&1; then
  echo 'Workspace mode allowed unsafe database identifier' >&2; exit 1
fi
# Missing test config in a legacy ignored Rails YAML should be derived
# from development, while leaving the original developer file untouched.
cat > "$work/development-only.yml" <<'YAML'
default: &default
  adapter: postgresql
  host: localhost
development:
  <<: *default
  database: original_development
production:
  <<: *default
  database: production_database
YAML
cp "$work/development-only.yml" "$work/development-only-original.yml"
ruby "$here/rails-config.rb" workspace "$work/development-only.yml" isolated_development isolated_test > "$work/development-only.log"
grep -Fq 'ENV.fetch("GITWO_DB_DEV", "isolated_development")' "$work/development-only.yml"
grep -Fq 'ENV.fetch("GITWO_DB_TEST", "isolated_test")' "$work/development-only.yml"
grep -Fq 'database: production_database' "$work/development-only.yml"
[[ "$(grep -c "^test:$" "$work/development-only.yml")" == 1 ]]
printf '[PASS] Rails config preview/apply, private workspace isolation, idempotence, unsafe-layout rejection\n'
