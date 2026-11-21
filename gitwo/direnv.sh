#!/usr/bin/env bash
# Loaded by direnv's source_env inside one registered Gitwo worktree.
# This script must not execute Rails code, start services, or change tracked files.
set -euo pipefail

# source_env invokes this file as ./direnv.sh, relative to its installation.
# Resolve its location before switching into the application worktree.
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

# direnv's source_env may evaluate this file outside the .envrc directory.
# Use the workspace path captured when the managed .envrc was generated.
# Explicit path is used by direnv. Direct verification already runs in the worktree.
workspace="$(cd -- "${GITWO_DIRENV_WORKSPACE:-$PWD}" && pwd -P)"
cd -- "$workspace"
GITWO_PROJECT_ROOT="$workspace"
export GITWO_PROJECT_ROOT
# Never inherit a previous workspace's calculated identifiers.
unset GITWO_STATE GITWO_ROOT GITWO_SOURCE GITWO_PROJECT_ID GITWO_CONFIG_FILE
# Preserve explicit CLI overrides such as GITWO_DB_PREFIX and GITWO_PROXY.
# direnv restores the pre-workspace environment before activating another one.

# _common.sh is also used by CLI commands, which disable pagers. A developer's
# interactive commands should keep their original pager and Git settings.
for var in PAGER GIT_PAGER GIT_TERMINAL_PROMPT GIT_OPTIONAL_LOCKS; do
  if [[ ${!var+x} ]]; then
    printf -v "_gitwo_saved_${var}" '%s' "${!var}"
    printf -v "_gitwo_had_${var}" 'yes'
  else
    printf -v "_gitwo_had_${var}" 'no'
  fi
done

source "$here/_common.sh"
source "$here/_runtime.sh"

for var in PAGER GIT_PAGER GIT_TERMINAL_PROMPT GIT_OPTIONAL_LOCKS; do
  had="_gitwo_had_${var}"
  saved="_gitwo_saved_${var}"
  if [[ ${!had} == yes ]]; then
    export "$var=${!saved}"
  else
    unset "$var"
  fi
  unset "$had"
  unset "$saved" 2>/dev/null || true
done
unset var had saved

branch="$(git -C "$workspace" branch --show-current)"
gitwo_check_source
gitwo_verify_target "$workspace" "$branch"
gitwo_validate_workspace_identity "$workspace" "$branch"
gitwo_load_state "$workspace"
gitwo_db_settings

slug="$(basename "$workspace")"
marker="$GITWO_STATE/${slug}.db-ready"
bootstrap="$GITWO_STATE/${slug}.bootstrap-status"
[[ -f "$marker" && ! -L "$marker" && "$(cat "$marker")" == "$GITWO_DB_DEV" ]] || gitwo_die 'Gitwo workspace database is not registered or ready'
[[ -f "$bootstrap" && ! -L "$bootstrap" && "$(cat "$bootstrap")" == ready ]] || gitwo_die 'Gitwo workspace bootstrap is not complete'
gitwo_runtime_existing_load "$workspace" || gitwo_die 'Gitwo workspace ports are missing; run gitwo workspace env init'

# A directory-wide DATABASE_URL would also apply to RSpec and Rails test,
# potentially sending destructive test operations to the development DB.
# Let Rails choose its DB per environment via explicit database.yml entries.
unset DATABASE_URL TEST_DATABASE_URL RAILS_ENV RACK_ENV REDIS_URL SIDEKIQ_REDIS_URL

export GITWO_WORKSPACE="$slug"
export GITWO_DB_DEV GITWO_DB_TEST
export GITWO_DEV_DATABASE_URL="$(gitwo_db_url "$GITWO_DB_DEV")"
export GITWO_TEST_DATABASE_URL="$(gitwo_db_url "$GITWO_DB_TEST")"
export GITWO_DEV_REDIS_URL="$(gitwo_redis_url development)"
export GITWO_TEST_REDIS_URL="$(gitwo_redis_url test)"
export PGHOST="$GITWO_DB_HOST" PGPORT="$GITWO_DB_PORT" PGUSER="$GITWO_DB_USER"
export DB_HOST="$GITWO_DB_HOST" DB_PORT="$GITWO_DB_PORT" DB_USERNAME="$GITWO_DB_USER"
export PORT="$WEB_PORT"
export GITWO_PORTLESS_HOST="$(gitwo_web_name "$workspace").localhost"
if [[ "$GITWO_PROXY" == portless ]]; then
  export APP_HOST="$GITWO_PORTLESS_HOST"
  export GITWO_APP_URL="https://$GITWO_PORTLESS_HOST"
  export RAILS_DEVELOPMENT_HOSTS="${RAILS_DEVELOPMENT_HOSTS:+${RAILS_DEVELOPMENT_HOSTS},}${GITWO_PORTLESS_HOST}"
else
  export APP_HOST="localhost:$PORT"
  export GITWO_APP_URL="http://localhost:$PORT"
fi

gitwo_ruby_version "$workspace"
if command -v mise >/dev/null 2>&1; then
  ruby_home="$(mise where "ruby@$GITWO_RUBY_VERSION" 2>/dev/null)" || gitwo_die "Ruby $GITWO_RUBY_VERSION is not installed in mise"
  [[ -d "$ruby_home/bin" ]] || gitwo_die 'Mise returned an invalid Ruby installation'
  export PATH="$ruby_home/bin:$PATH"
fi

# No global REDIS_URL: test and development may clear Redis independently.
# Applications can select GITWO_{DEV,TEST}_REDIS_URL by Rails.env.
unset workspace slug branch marker bootstrap ruby_home here
