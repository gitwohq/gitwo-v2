#!/usr/bin/env bash
# Verify that generic Rails setup does not create a DB for unsupported Rake config.
set -euo pipefail
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/gitwo-rails-standard.XXXXXXXX")"
trap 'rm -rf -- "$tmp"' EXIT
cd "$tmp"
mkdir -p config lib/tasks
GITWO_DIR="$here"
GITWO_DB_DEV=fixture_feature_1_development
GITWO_DB_TEST=fixture_feature_1_test
gitwo_log() { printf '[INFO] %s\n' "$*" >&2; }
gitwo_warn() { printf '[WARN] %s\n' "$*" >&2; }
gitwo_die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }
source "$here/adapters/rails-standard.sh"

# Pure DATABASE_URL Rails apps can legitimately omit database.yml.
gitwo_adapter_prepare_database_config > "$tmp/no-custom.log" 2>&1

# A custom task evaluated while Rake loads must have an actual config file.
cat > lib/tasks/db.rake <<'RUBY'
namespace :db do
  database = Rails.application.config_for(:database)
  desc "Dump #{database.fetch(:database)}"
  task :custom_dump do
  end
end
RUBY
if (gitwo_adapter_prepare_database_config) > "$tmp/missing.log" 2>&1; then
  echo 'Custom Rake config unexpectedly accepted without database.yml' >&2
  exit 1
fi
grep -Fq 'Missing config/database.yml' "$tmp/missing.log"
grep -Fq "$GITWO_DB_DEV" "$tmp/missing.log"

cat > config/database.yml <<YAML
development:
  adapter: postgresql
  database: $GITWO_DB_DEV
test:
  adapter: postgresql
  database: $GITWO_DB_TEST
YAML
gitwo_adapter_prepare_database_config > "$tmp/existing.log" 2>&1
grep -Fq 'Custom Rake tasks read config_for(:database)' "$tmp/existing.log"

rm config/database.yml
ln -s "$tmp/nonexistent" config/database.yml
if (gitwo_adapter_prepare_database_config) > "$tmp/symlink.log" 2>&1; then
  echo 'Symlinked database.yml unexpectedly accepted' >&2
  exit 1
fi
grep -Fq 'Refusing symlinked config/database.yml' "$tmp/symlink.log"
printf '[PASS] Rails config_for preflight before database bootstrap\n'
