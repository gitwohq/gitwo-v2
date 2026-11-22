#!/usr/bin/env bash
# Workspace-scoped service backend control. Native mode is read-only here.
set -euo pipefail
source "$(cd -- "$(dirname -- "$0")" && pwd -P)/_common.sh"
[[ $# -ge 1 && $# -le 2 ]] || { echo 'Usage: gitwo services <up|down|status> [WORKSPACE]' >&2; exit 2; }
action="$1"
case "$action" in up|down|status) ;; *) gitwo_die 'Use services up, down or status' ;; esac
selector=''
[[ $# -eq 1 ]] || selector="$2"
gitwo_check_source
target="$(gitwo_resolve_path "$selector")"
branch="$(git -C "$target" branch --show-current)"
gitwo_verify_target "$target" "$branch"
gitwo_validate_workspace_identity "$target" "$branch"
[[ "$GITWO_SERVICES_BACKEND" == compose ]] || {
  [[ "$action" == status ]] || gitwo_die 'Native services are managed through gitwo up, down and redis'
  printf 'Workspace %s uses native PostgreSQL and Redis\n' "$(basename "$target")"
  exit 0
}
gitwo_need docker
case "$action" in
  up) gitwo_compose_up "$target" ;;
  down) gitwo_compose_down "$target" ;;
  status) gitwo_compose_cli "$target" ps ;;
esac
