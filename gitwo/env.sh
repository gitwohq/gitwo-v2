#!/usr/bin/env bash
# Display only Gitwo's allowlisted runtime settings, never application secrets.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/_common.sh"
source "$GITWO_DIR/_runtime.sh"
selector='' format=text
for arg in "$@"; do
  case "$arg" in
    -h|--help) printf 'Usage: gitwo env [WORKSPACE] [--json]\nShow computed Gitwo runtime ENV, not .env contents or secrets.\n'; exit 0 ;;
    --json) format=json ;;
    -*) gitwo_die "Unknown env option: $arg" ;;
    *) [[ -z "$selector" ]] || gitwo_die 'Only one workspace selector allowed'; selector="$arg" ;;
  esac
done
gitwo_check_source
target="$(gitwo_resolve_path "$selector")"
branch="$(git -C "$target" branch --show-current)"
gitwo_verify_target "$target" "$branch"
gitwo_validate_workspace_identity "$target" "$branch"
gitwo_db_settings
db="$(gitwo_expected_db_name "$target" development)"
test_db="$(gitwo_expected_db_name "$target" test)"
redis='not-allocated'
if gitwo_runtime_existing_load "$target"; then
  redis="redis://127.0.0.1:${REDIS_DEV_PORT}/0"
fi
app_host="$(gitwo_web_name "$target").localhost"
# These values are generated, not read from the project's .env or secret storage.
if [[ "$format" == json ]]; then
  GITWO_PUBLIC_WORKSPACE="$(basename "$target")" \
    GITWO_PUBLIC_RAILS_ENV=development GITWO_PUBLIC_RACK_ENV=development \
    GITWO_PUBLIC_APP_HOST="$app_host" \
    GITWO_PUBLIC_DATABASE_URL="$(gitwo_db_url "$db")" \
    GITWO_PUBLIC_TEST_DATABASE_URL="$(gitwo_db_url "$test_db")" \
    GITWO_PUBLIC_REDIS_URL="$redis" \
    ruby -rjson -e 'keys=%w[WORKSPACE RAILS_ENV RACK_ENV APP_HOST DATABASE_URL TEST_DATABASE_URL REDIS_URL]; puts JSON.pretty_generate(Hash[keys.map { |k| [k, ENV.fetch("GITWO_PUBLIC_" + k)] }])' 
else
  printf 'Gitwo computed environment (secrets omitted; not the complete Rails ENV)\n'
  printf '  WORKSPACE=%s\n  RAILS_ENV=development\n  RACK_ENV=development\n  APP_HOST=%s\n  DATABASE_URL=%s\n  TEST_DATABASE_URL=%s\n  REDIS_URL=%s\n' \
    "$(basename "$target")" "$app_host" "$(gitwo_db_url "$db")" "$(gitwo_db_url "$test_db")" "$redis"
  printf '  Provider credentials=[redacted/not loaded]\n'
fi
