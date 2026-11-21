#!/usr/bin/env bash
# Read-only workspace inspection. Never start services, create ports or adopt databases.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/_common.sh"
source "$GITWO_DIR/_runtime.sh"
source "$GITWO_DIR/_lifecycle.sh"
usage() { printf 'Usage: gitwo status [WORKSPACE] [--json] [--check-http]\nRead-only status. HTTP checks are opt-in.\n'; }
selector='' format=text check_http=no
for arg in "$@"; do
  case "$arg" in
    --help|-h) usage; exit 0 ;;
    --json) format=json ;;
    --check-http) check_http=yes ;;
    -*) gitwo_die "Unknown status flag: $arg" ;;
    *) [[ -z "$selector" ]] || { usage >&2; exit 2; }; selector="$arg" ;;
  esac
done
gitwo_need git
gitwo_check_source
target="$(gitwo_resolve_path "$selector")"
if [[ "$format" == json ]]; then
  # Reuse the same read-only inspection as the human display.
  status_args=("$target")
  [[ "$check_http" == no ]] || status_args+=(--check-http)
  report='' exit_code=0
  report="$("$GITWO_DIR/status.sh" "${status_args[@]}" 2>/dev/null)" || exit_code=$?
  GITWO_REPORT="$report" GITWO_EXIT_CODE="$exit_code" ruby -rjson -e '
    lines=ENV.fetch("GITWO_REPORT").lines
    result={"status"=>ENV.fetch("GITWO_EXIT_CODE")=="0" ? "ok" : "degraded"}
    lines.each do |line|
      match=line.match(/^  ([A-Za-z][A-Za-z ]+?)\s{2,}(.+)$/)
      next unless match
      key=match[1].strip.downcase.tr(" ", "_")
      result[key]=match[2].strip
    end
    puts JSON.pretty_generate(result)
  '
  exit "$exit_code"
fi
branch="$(git -C "$target" branch --show-current)"
gitwo_verify_target "$target" "$branch"
slug="$(basename "$target")"
gitwo_validate_workspace_identity "$target" "$branch"
expected_dev="$(gitwo_expected_db_name "$target" development)"
state_file="$GITWO_STATE/${slug}.env"
db_marker="$GITWO_STATE/${slug}.db-ready"
seed_marker="$GITWO_STATE/${slug}.seed-status"
bootstrap_marker="$GITWO_STATE/${slug}.bootstrap-status"
data_marker="$GITWO_STATE/${slug}.data-source"
failed=0
field() { printf '  %-16s %s\n' "$1" "$2"; }
read_marker() {
  if [[ ! -e "$1" && ! -L "$1" ]]; then printf 'unknown\n'; return 0; fi
  if [[ ! -f "$1" || -L "$1" ]]; then printf 'UNSAFE PATH\n'; return 1; fi
  cat "$1"
}

printf 'gitwo / workspace status\n'
field Workspace "$slug"
created_marker="$GITWO_STATE/${slug}.created-at"
if [[ ! -e "$created_marker" && ! -L "$created_marker" ]]; then
  field 'Created at' 'unknown (legacy workspace)'
elif [[ -f "$created_marker" && ! -L "$created_marker" ]] &&
     [[ "$(cat "$created_marker")" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
  field 'Created at' "$(cat "$created_marker")"
else
  field 'Created at' 'invalid metadata'
  failed=1
fi
field Branch "$branch"
field 'Git changes' "$(git -C "$target" status --short | wc -l | tr -d ' ') entries"
if [[ "${GITWO_PROXY:-none}" == none ]]; then
  if gitwo_runtime_existing_load "$target"; then
    field URL "http://127.0.0.1:${WEB_PORT}"
  else
    field URL 'direct port not allocated'
  fi
else
  field URL "$(gitwo_web_url "$target")"
fi
field Database "$expected_dev"
if [[ -f "$state_file" && ! -L "$state_file" ]]; then
  field 'Workspace state' present
else
  field 'Workspace state' 'missing or unsafe'
  failed=1
fi
if [[ -f "$db_marker" && ! -L "$db_marker" && "$(cat "$db_marker")" == "$expected_dev" ]]; then
  field 'DB ownership' verified
else
  field 'DB ownership' 'unregistered or invalid'
  failed=1
fi

bootstrap="$(read_marker "$bootstrap_marker")" || failed=1
case "$bootstrap" in
  ready) field Bootstrap ready ;;
  unknown) field Bootstrap 'unknown (legacy workspace)' ;;
  running|failed) field Bootstrap "$bootstrap (requires inspection)"; failed=1 ;;
  *) field Bootstrap "unexpected: $bootstrap"; failed=1 ;;
esac
seed="$(read_marker "$seed_marker")" || failed=1
case "$seed" in
  ready) field Seeds 'complete (recorded)' ;;
  unknown) field Seeds 'not recorded (possibly adopted, dump or --no-seed)' ;;
  running|failed) field Seeds "$seed (requires inspection)"; failed=1 ;;
  *) field Seeds "unexpected: $seed"; failed=1 ;;
esac
source_type="$(read_marker "$data_marker")" || failed=1
case "$source_type" in
  seeded|schema-only|baseline|dump:*) field 'Data source' "$source_type" ;;
  unknown) field 'Data source' 'unknown (legacy or adopted DB)' ;;
  *) field 'Data source' 'invalid metadata'; failed=1 ;;
esac

GITWO_PATH="$target"
gitwo_db_settings
if command -v psql >/dev/null 2>&1; then
  if existing="$(gitwo_pg psql --no-psqlrc -w -d postgres -Atqc "SELECT 1 FROM pg_database WHERE datname = '$expected_dev'" 2>/dev/null)"; then
    if [[ "$existing" == 1 ]]; then
      field PostgreSQL connected
      if tables="$(gitwo_pg psql --no-psqlrc -w -d "$expected_dev" -Atqc "SELECT count(*) FROM pg_catalog.pg_tables WHERE schemaname = 'public'" 2>/dev/null)"; then
        if [[ "$tables" =~ ^[0-9]+$ ]] && (( tables > 0 )); then
          field 'Public tables' "$tables"
        else
          field 'Public tables' "$tables (unexpected: no Rails tables)"
          failed=1
        fi
      else
        field 'Public tables' 'not readable'
      fi
    else
      field PostgreSQL 'workspace database missing'
      failed=1
    fi
  else
    field PostgreSQL 'unavailable (read-only check failed)'
    failed=1
  fi
else
  field PostgreSQL 'psql not installed'
  failed=1
fi

ports="$GITWO_STATE/runtime/${slug}.ports"
if [[ ! -e "$ports" && ! -L "$ports" ]]; then
  field Redis 'not allocated'
elif [[ -f "$ports" && ! -L "$ports" ]] && [[ "$(wc -l < "$ports" | tr -d ' ')" == 3 ]] &&
     grep -Eq '^REDIS_DEV_PORT=[0-9]{4,5}$' "$ports" &&
     grep -Eq '^REDIS_TEST_PORT=[0-9]{4,5}$' "$ports" &&
     grep -Eq '^WEB_PORT=[0-9]{4,5}$' "$ports"; then
  dev_port="$(awk -F= '$1=="REDIS_DEV_PORT" {print $2}' "$ports")"
  if command -v redis-cli >/dev/null 2>&1 &&
     [[ "$(redis-cli -h 127.0.0.1 -p "$dev_port" --raw ping 2>/dev/null || true)" == PONG ]]; then
    field Redis "responding on 127.0.0.1:$dev_port (ownership not verified)"
  else
    field Redis "stopped/unreachable (assigned port $dev_port)"
  fi
else
  field Redis 'invalid runtime metadata'
  failed=1
fi
field Puma "$(gitwo_puma_status "$target")"
sidekiq_pids="$(gitwo_sidekiq_pids "$target")"
if [[ -n "$sidekiq_pids" ]]; then field Sidekiq "running (PID $sidekiq_pids)"; else field Sidekiq stopped; fi
if [[ "$check_http" == yes ]]; then
  if [[ "${GITWO_PROXY:-portless}" == none ]]; then
    if gitwo_runtime_existing_load "$target"; then
      http_url="http://127.0.0.1:$WEB_PORT/"
    else
      http_url=''
    fi
  else
    http_url="$(gitwo_web_url "$target")"
  fi
  if [[ -z "$http_url" ]] || ! command -v curl >/dev/null 2>&1; then
    field HTTP 'unavailable (curl missing or no URL)'
    failed=1
  else
    # Verify HTTPS certificates. Portless uses a private CA; never use curl -k.
    curl_ca=()
    if [[ "$http_url" == https://* && -f "$HOME/.portless/ca.pem" && ! -L "$HOME/.portless/ca.pem" ]]; then
      curl_ca=(--cacert "$HOME/.portless/ca.pem")
    elif [[ "$http_url" == https://* && -d "$HOME/.portless/ca.pem" ]]; then
      field HTTP 'invalid Portless CA path (directory)'
      exit 1
    fi
    http_code="$(curl "${curl_ca[@]}" -sS -o /dev/null -w '%{http_code}' --connect-timeout 2 --max-time 5 "$http_url" 2>/dev/null)" || http_code=000
    if [[ "$http_code" =~ ^[23][0-9]{2}$ ]]; then
      field HTTP "healthy ($http_code)"
    elif [[ "$http_code" == 000 ]]; then
      field HTTP 'unreachable'
      failed=1
    else
      field HTTP "requires attention ($http_code)"
      failed=1
    fi
  fi
fi
exit "$failed"
