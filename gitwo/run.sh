#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/_common.sh"
source "$GITWO_DIR/_runtime.sh"
source "$GITWO_DIR/_lifecycle.sh"
source "$GITWO_DIR/_prepare.sh"
source "$GITWO_DIR/_testing.sh"
source "$GITWO_DIR/_launcher.sh"
usage() { cat >&2 <<'USAGE'
Usage: run.sh [WORKSPACE|ENG-5303-feature-1] <server|test|minitest|rspec|rails|console|sidekiq> [args...]
  server    Start isolated Redis and the app's dev launcher via Portless or direct port
            Options before 'server': --launcher=auto|rails|bin-dev|foreman|overmind
                                     --dry-run [--json], --json or --detach [--json]
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
selector='' requested_launcher="${GITWO_LAUNCHER:-auto}" explicit_launcher=no preview=no detach=no format=text
# Parse the optional workspace and server flags before the run mode. This
# preserves the existing `gitwo up [WORKSPACE]` and `gitwo run ...` contracts.
while [[ $# -gt 0 ]]; do
  case "$1" in
    --launcher=*) requested_launcher="${1#*=}"; explicit_launcher=yes; shift ;;
    --dry-run) preview=yes; shift ;;
    --detach) detach=yes; shift ;;
    --json) format=json; shift ;;
    --help|-h) usage; exit 0 ;;
    *)
      if [[ -z "$selector" &&
          ( "$1" =~ ^[A-Za-z][A-Za-z0-9]{1,14}-[0-9]+(-(feature|hotfix|bugfix))?(-[0-9]+)?$ ||
            "$1" =~ ^develop-[1-9][0-9]*$ ||
            "$1" =~ ^[a-z][a-z0-9]*(-[a-z0-9]+)*-[1-9][0-9]*$ ||
            "$1" == /* ) ]]; then
        selector="$1"; shift
      else
        break
      fi
      ;;
  esac
done
[[ $# -ge 1 ]] || { usage; exit 2; }
what="$1"; shift
if [[ "$what" != server && ( "$preview" == yes || "$format" == json || "$explicit_launcher" == yes || "$detach" == yes ) ]]; then
  gitwo_die 'Launcher, dry-run, detach and JSON flags are supported only for gitwo up / server'
fi
[[ "$preview" != yes || "$detach" != yes ]] || gitwo_die 'Cannot combine --dry-run with --detach'
gitwo_need git
gitwo_check_source
target="$(gitwo_resolve_path "$selector")"
launcher=''
if [[ "$what" == server ]]; then
  launcher="$(gitwo_launcher_detect "$target" "$requested_launcher")" ||
    gitwo_die 'Cannot select a safe development launcher'
  if [[ "$preview" == yes ]]; then
    if [[ "$format" == json ]]; then
      GITWO_PREVIEW_PATH="$target" GITWO_PREVIEW_LAUNCHER="$launcher" \
        GITWO_PREVIEW_PROXY="$GITWO_PROXY" GITWO_PREVIEW_URL="$(gitwo_web_url "$target")" \
        ruby -rjson -e 'puts JSON.generate({status: "plan", workspace: File.basename(ENV.fetch("GITWO_PREVIEW_PATH")), path: ENV.fetch("GITWO_PREVIEW_PATH"), launcher: ENV.fetch("GITWO_PREVIEW_LAUNCHER"), proxy: ENV.fetch("GITWO_PREVIEW_PROXY"), url: ENV.fetch("GITWO_PREVIEW_PROXY") == "portless" ? ENV.fetch("GITWO_PREVIEW_URL") : nil})'
    else
      printf 'Workspace: %s\nLauncher:  %s\nProxy:     %s\nNo processes or services started.\n' "$target" "$launcher" "$GITWO_PROXY"
    fi
    exit 0
  fi
  # An agent must never wait at a database-adoption question.
  if [[ "$format" == json || "$detach" == yes || ! -t 0 ]]; then export GITWO_NON_INTERACTIVE=1; fi
  gitwo_need mise
  # A first-time setup or legacy metadata recovery can write to stdout.
  # Keep stdout strictly machine-readable for the headless startup event.
  if [[ "$format" == json ]]; then
    gitwo_up_prepare "$target" 1>&2
  else
    gitwo_up_prepare "$target"
  fi
else
  gitwo_need mise
fi
gitwo_load_state "$target"; gitwo_db_settings; gitwo_ruby_version "$target"
cd "$target"
case "$what" in
  server)
    log_dir="$(_gitwo_runtime_dir "$target")"
    current_puma="$(gitwo_puma_status "$target")"
    case "$current_puma" in
      stopped*) ;;
      running*) gitwo_die "Puma already running for $(basename "$target"): $current_puma" ;;
      *) gitwo_die "Cannot safely start server: $current_puma" ;;
    esac
    if [[ "$detach" == yes ]]; then
      # A dedicated process-group leader owns the whole launcher session. It
      # verifies PID/start time/token before stopping any child processes.
      if [[ "$launcher" == overmind ]]; then
        gitwo_die 'Detached Overmind uses tmux sessions outside the launcher process group; use foreground up until a verified Overmind session adapter exists'
      fi
      if [[ "${GITWO_PROXY:-none}" == portless ]]; then
        url="$(gitwo_web_url "$target")"
      else
        gitwo_runtime_load "$target"
        url="http://127.0.0.1:${GITWO_PORT:-$WEB_PORT}"
      fi
      ruby "$GITWO_DIR/supervisor.rb" start "$target" "$log_dir" "$GITWO_DIR/run.sh" "$launcher" "$url" "$format" "$@"
      exit $?
    fi
    # An existing detached launcher must not be duplicated by a foreground up.
    if [[ -f "$log_dir/supervisor.json" || -L "$log_dir/supervisor.json" ]]; then
      managed="$(ruby "$GITWO_DIR/supervisor.rb" status "$target" "$log_dir")" ||
        gitwo_die 'Unverified supervisor state; refusing duplicate launcher'
      if [[ -n "${GITWO_SUPERVISED_CHILD:-}" ]]; then
        ruby "$GITWO_DIR/supervisor.rb" verify-child "$target" "$log_dir" "$GITWO_SUPERVISED_CHILD" ||
          gitwo_die 'Detached child does not match the active supervisor session'
      else
        [[ "$managed" != running* ]] || gitwo_die "Supervised launcher already running: $managed"
      fi
    fi
    [[ ! -L "$log_dir" ]] || gitwo_die "Unsafe runtime log directory: $log_dir"
    (umask 077; mkdir -p "$log_dir"; touch "$log_dir/puma.log")
    [[ -f "$log_dir/puma.log" && ! -L "$log_dir/puma.log" ]] || gitwo_die 'Unsafe Puma log path'
    chmod 600 "$log_dir/puma.log"
    name="$(gitwo_web_name "$target")"
    if [[ "$launcher" != rails && -f "$target/vite.config.ts" ||
          "$launcher" != rails && -f "$target/vite.config.js" ||
          "$launcher" != rails && -f "$target/vite.config.mts" ]]; then
      gitwo_warn 'Vite detected: Gitwo routes the web process only. Verify Vite HMR/WebSocket configuration for this hostname.'
    fi
    gitwo_log "Development launcher: $launcher"
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
      # Route the application's existing launcher, not only Puma. Portless
      # assigns PORT to the child; Foreman/Overmind apply it to their web proc.
      allowed_host="${name}.localhost"
      if [[ "$format" == json ]]; then
        GITWO_OUTPUT_WORKSPACE="$(basename "$target")" GITWO_OUTPUT_LAUNCHER="$launcher" \
          GITWO_OUTPUT_URL="$(gitwo_web_url "$target")" ruby -rjson -e 'puts JSON.generate({status: "starting", workspace: ENV.fetch("GITWO_OUTPUT_WORKSPACE"), launcher: ENV.fetch("GITWO_OUTPUT_LAUNCHER"), url: ENV.fetch("GITWO_OUTPUT_URL")})'
      fi
      if [[ "$format" == json ]]; then
        RAILS_DEVELOPMENT_HOSTS="${RAILS_DEVELOPMENT_HOSTS:+${RAILS_DEVELOPMENT_HOSTS},}${allowed_host}" \
          GITWO_APP_HOST="$allowed_host" GITWO_APP_URL="$(gitwo_web_url "$target")" \
          gitwo_rails development portless "$name" "$GITWO_DIR/_launcher.sh" exec "$launcher" "$@" 2>&1 | tee -a "$log_dir/puma.log" >&2
      else
        RAILS_DEVELOPMENT_HOSTS="${RAILS_DEVELOPMENT_HOSTS:+${RAILS_DEVELOPMENT_HOSTS},}${allowed_host}" \
          GITWO_APP_HOST="$allowed_host" GITWO_APP_URL="$(gitwo_web_url "$target")" \
          gitwo_rails development portless "$name" "$GITWO_DIR/_launcher.sh" exec "$launcher" "$@" 2>&1 | tee -a "$log_dir/puma.log"
      fi
    elif [[ "${GITWO_PROXY}" == none ]]; then
      gitwo_runtime_environment "$target" development
      gitwo_runtime_load "$target"
      port="${GITWO_PORT:-$WEB_PORT}"
      [[ "$port" =~ ^[0-9]{4,5}$ ]] || gitwo_die "Invalid direct web port: $port"
      gitwo_log "Application at http://localhost:$port (direct mode)"
      if [[ "$format" == json ]]; then
        GITWO_OUTPUT_WORKSPACE="$(basename "$target")" GITWO_OUTPUT_LAUNCHER="$launcher" \
          GITWO_OUTPUT_URL="http://localhost:$port" ruby -rjson -e 'puts JSON.generate({status: "starting", workspace: ENV.fetch("GITWO_OUTPUT_WORKSPACE"), launcher: ENV.fetch("GITWO_OUTPUT_LAUNCHER"), url: ENV.fetch("GITWO_OUTPUT_URL")})'
        GITWO_APP_HOST="localhost:$port" GITWO_APP_URL="http://localhost:$port" PORT="$port" \
          gitwo_rails development "$GITWO_DIR/_launcher.sh" exec "$launcher" "$@" 2>&1 | tee -a "$log_dir/puma.log" >&2
      else
        GITWO_APP_HOST="localhost:$port" GITWO_APP_URL="http://localhost:$port" PORT="$port" \
          gitwo_rails development "$GITWO_DIR/_launcher.sh" exec "$launcher" "$@" 2>&1 | tee -a "$log_dir/puma.log"
      fi
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
