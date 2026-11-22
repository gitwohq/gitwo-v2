#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/_common.sh"
source "$GITWO_DIR/_runtime.sh"
source "$GITWO_DIR/_lifecycle.sh"
source "$GITWO_DIR/_prepare.sh"
source "$GITWO_DIR/_testing.sh"
usage() { cat >&2 <<'USAGE'
Usage: run.sh [WORKSPACE|ENG-5303-feature-1] <server|test|minitest|rspec|rails|console|sidekiq> [args...]
  server    Start isolated Redis and Puma via Portless at https://<workspace>.<domain>.localhost
  test      Auto-select Minitest or RSpec (errors if both are configured)
  minitest  Run Rails Minitest with isolated test PostgreSQL and Redis
  rspec     Run RSpec with isolated test PostgreSQL and Redis
  rails     Run Rails task with isolated development DB and Redis
  console   Start Rails console with isolated development DB and Redis
  sidekiq   Start worker using workspace Redis (requires GITWO_ENABLE_SIDEKIQ=1)
Use GITWO_PROXY=none to run Puma without Portless on an allocated local TCP port.
USAGE
}
if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then usage; exit 0; fi
[[ $# -ge 1 ]] || { usage; exit 2; }
selector=''
if [[ "${1:-}" =~ ^[A-Za-z][A-Za-z0-9]{1,14}-[0-9]+(-(feature|hotfix|bugfix))?(-[0-9]+)?$ ||
      "${1:-}" =~ ^develop-[1-9][0-9]*$ ||
      "${1:-}" =~ ^[a-z][a-z0-9]*(-[a-z0-9]+)*-[1-9][0-9]*$ ||
      "${1:-}" == /* ]]; then
  selector="$1"; shift
fi
[[ $# -ge 1 ]] || { usage; exit 2; }
what="$1"; shift
gitwo_need git; gitwo_need mise
gitwo_check_source
target="$(gitwo_resolve_path "$selector")"
# Only `gitwo up` / server performs safe self-initialization.
# Other run subcommands retain their explicit setup requirement.
if [[ "$what" == server ]]; then
  gitwo_up_prepare "$target"
fi
gitwo_load_state "$target"; gitwo_db_settings; gitwo_ruby_version "$target"
cd "$target"
case "$what" in
  server)
    current_puma="$(gitwo_puma_status "$target")"
    case "$current_puma" in
      stopped*) ;;
      running*) gitwo_die "Puma already running for $(basename "$target"): $current_puma" ;;
      *) gitwo_die "Cannot safely start server: $current_puma" ;;
    esac
    log_dir="$(_gitwo_runtime_dir "$target")"
    [[ ! -L "$log_dir" ]] || gitwo_die "Unsafe runtime log directory: $log_dir"
    (umask 077; mkdir -p "$log_dir"; touch "$log_dir/puma.log")
    [[ -f "$log_dir/puma.log" && ! -L "$log_dir/puma.log" ]] || gitwo_die 'Unsafe Puma log path'
    chmod 600 "$log_dir/puma.log"
    name="$(gitwo_web_name "$target")"
    if [[ "${GITWO_PROXY:-portless}" == portless ]]; then
      [[ ! -e "$GITWO_STATE/runtime/$(basename "$target").portless-alias" ]] || gitwo_die 'Native Portless alias registered. Use bin/rails server or unregister the workspace proxy before gitwo up.'
      gitwo_need portless
      node_major="$(node -p 'parseInt(process.versions.node.split(".")[0], 10)')"
      [[ "$node_major" -ge 24 ]] || gitwo_die "Portless requires Node.js >=24 (current: $(node -v)); set GITWO_PROXY=none for direct mode"
      gitwo_runtime_environment "$target" development
      gitwo_log "Rails at $(gitwo_web_url "$target")"
      gitwo_log "Redis at $REDIS_URL (dedicated instance)"
      # Explicit dotted service name bypasses Portless auto-prefixed branch naming.
      # Portless sets PORT to a free internal port; do NOT pass a fixed -p here.
      # Rails 7.2 supports RAILS_DEVELOPMENT_HOSTS without changing tracked Rails files.
      # Permit the exact Portless hostname, keeping any user-supplied allowed hosts.
      allowed_host="${name}.localhost"
      RAILS_DEVELOPMENT_HOSTS="${RAILS_DEVELOPMENT_HOSTS:+${RAILS_DEVELOPMENT_HOSTS},}${allowed_host}" \
        GITWO_APP_HOST="$allowed_host" \
        gitwo_rails development portless "$name" bundle exec rails server -b 127.0.0.1 "$@" 2>&1 | tee -a "$log_dir/puma.log"
    elif [[ "${GITWO_PROXY}" == none ]]; then
      gitwo_runtime_environment "$target" development
      gitwo_runtime_load "$target"
      port="${GITWO_PORT:-$WEB_PORT}"
      [[ "$port" =~ ^[0-9]{4,5}$ ]] || gitwo_die "Invalid direct web port: $port"
      gitwo_log "Rails at http://localhost:$port (direct mode)"
      GITWO_APP_HOST="localhost:$port" gitwo_rails development bundle exec rails server -b 127.0.0.1 -p "$port" "$@" 2>&1 | tee -a "$log_dir/puma.log"
    else
      gitwo_die 'GITWO_PROXY must be portless or none'
    fi
    ;;
  test|minitest|rspec)
    gitwo_runtime_environment "$target" test
    gitwo_test_run "$what" "$@"
    ;;
  rails)
    [[ "${1:-}" != db:drop && "${1:-}" != db:reset ]] || gitwo_die 'Destructive DB tasks are intentionally blocked'
    gitwo_runtime_environment "$target" development
    gitwo_rails development bundle exec rails "$@"
    ;;
  console)
    gitwo_runtime_environment "$target" development
    gitwo_rails development bundle exec rails console "$@"
    ;;
  sidekiq)
    [[ "${GITWO_ENABLE_SIDEKIQ:-}" == 1 ]] || gitwo_die 'Sidekiq disabled by default. Set GITWO_ENABLE_SIDEKIQ=1 after reviewing external integrations.'
    gitwo_runtime_environment "$target" development
    gitwo_warn 'Confirm this application and its Sidekiq initializer actually honor REDIS_URL; inspect external integrations before allowing jobs.'
    log_dir="$(_gitwo_runtime_dir "$target")"
    [[ ! -L "$log_dir" ]] || gitwo_die "Unsafe runtime log directory: $log_dir"
    (umask 077; mkdir -p "$log_dir"; touch "$log_dir/sidekiq.log")
    [[ -f "$log_dir/sidekiq.log" && ! -L "$log_dir/sidekiq.log" ]] || gitwo_die 'Unsafe Sidekiq log path'
    chmod 600 "$log_dir/sidekiq.log"
    if [[ "$GITWO_ADAPTER" == rails-standard && ! -f config/sidekiq.yml ]]; then
      GITWO_APP_HOST="$(gitwo_web_name "$target").localhost" gitwo_rails development bundle exec sidekiq "$@" 2>&1 | tee -a "$log_dir/sidekiq.log"
    else
      GITWO_APP_HOST="$(gitwo_web_name "$target").localhost" gitwo_rails development bundle exec sidekiq -C config/sidekiq.yml "$@" 2>&1 | tee -a "$log_dir/sidekiq.log"
    fi
    ;;
  *) usage; gitwo_die "Unknown command: $what" ;;
esac
