#!/usr/bin/env bash
# Manage the private Redis processes owned by a particular Gitwo worktree.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/_common.sh"
source "$GITWO_DIR/_runtime.sh"
usage() { printf 'Usage: redis.sh <start|stop|status> [ENG-5303-feature-1]\n' >&2; }
if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then usage; exit 0; fi
[[ $# -ge 1 ]] || { usage; exit 2; }
action="$1"; shift
[[ "$action" == start || "$action" == stop || "$action" == status ]] || { usage; exit 2; }
[[ $# -le 1 ]] || { usage; exit 2; }
gitwo_check_source
target="$(gitwo_resolve_path "${1:-}")"
gitwo_load_state "$target"
gitwo_runtime_load "$target"
case "$action" in
  start)
    gitwo_redis_start "$target" development
    gitwo_redis_start "$target" test
    ;;
  stop)
    gitwo_need redis-cli
    gitwo_redis_stop "$target" development
    gitwo_redis_stop "$target" test
    ;;
  status)
    printf 'Workspace: %s\n' "$(basename "$target")"
    printf 'Web URL:   %s\n' "$(gitwo_web_url "$target")"
    printf 'Postgres:  %s\n' "$GITWO_DB_DEV"
    for mode in development test; do
      port="$(_gitwo_redis_port "$mode")"
      if command -v redis-cli >/dev/null 2>&1 && [[ "$(_gitwo_redis_cli "$port" PING 2>/dev/null || true)" == PONG ]]; then
        if _gitwo_redis_is_owned "$target" "$mode" "$port"; then status=running; else status="foreign (unsafe)"; fi
      else
        status=stopped
      fi
      printf 'Redis %-11s 127.0.0.1:%s (%s)\n' "$mode" "$port" "$status"
    done
    printf 'Direct web port: %s (used only with GITWO_PROXY=none)\n' "$WEB_PORT"
    ;;
esac
