#!/usr/bin/env bash
# Audit stale local Gitwo resources. Explicit opt-in only for abandoned port reservations.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/_common.sh"
source "$GITWO_DIR/_runtime.sh"
usage() { cat <<'USAGE'
Usage: gitwo clean [--json] [--prune-ports=WORKSPACE]
  (default)               Audit orphaned state and runtime port allocations (read-only)
  --json                  Print inventory as JSON (read-only)
  --prune-ports=WORKSPACE  Release a stopped, orphaned port reservation after confirmation
This command never deletes Git worktrees, PostgreSQL databases or historical state.
USAGE
}
mode=text; prune=''
for arg in "$@"; do
  case "$arg" in
    -h|--help) usage; exit 0 ;;
    --json) mode=json ;;
    --prune-ports=*) prune="${arg#--prune-ports=}" ;;
    *) gitwo_die "Unknown clean argument: $arg" ;;
  esac
done
[[ "$mode" != json || -z "$prune" ]] || gitwo_die 'Cannot combine --json and --prune-ports'
gitwo_check_source
[[ -d "$GITWO_STATE" && ! -L "$GITWO_STATE" ]] || gitwo_die 'Missing or unsafe state directory'
# Gitworktree authoritative inventory. Do not rely on filesystem naming alone.
active="$(git -C "$GITWO_SOURCE" worktree list --porcelain | sed -n 's/^worktree //p')"
workspace_exists() {
  local item="$1" path
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    [[ "$(basename "$path")" != "$item" ]] || return 0
  done <<< "$active"
  return 1
}
if [[ -n "$prune" ]]; then
  [[ "$prune" =~ ^[a-z0-9][a-z0-9_-]{0,80}$ ]] || gitwo_die 'Unsafe workspace name'
  workspace_exists "$prune" && gitwo_die "Workspace still exists: $prune"
  ports="$GITWO_STATE/runtime/$prune.ports"
  [[ -f "$ports" && ! -L "$ports" ]] || gitwo_die "No safe port reservation: $ports"
  # Do not trust a now-unused PID; no port may be bound by anything.
  gitwo_runtime_existing_load "$GITWO_ROOT/$prune"
  for port in "$REDIS_DEV_PORT" "$REDIS_TEST_PORT" "$WEB_PORT"; do
    _gitwo_runtime_port_free "$port" || gitwo_die "Port $port is bound. Refusing to release this reservation."
  done
  [[ -t 0 ]] || gitwo_die 'Cleanup confirmation requires a terminal'
  printf 'Type "%s" to release its orphaned PORT RESERVATION only: ' "$prune" >&2
  IFS= read -r answer || gitwo_die 'Cancelled'
  [[ "$answer" == "$prune" ]] || gitwo_die 'Confirmation mismatch'
  rm -- "$ports"
  gitwo_ok "Released orphaned port reservation for $prune (DBs, logs and state kept)"
  exit 0
fi
orphan_names=()
for path in "$GITWO_STATE"/*.env "$GITWO_STATE"/runtime/*.ports "$GITWO_STATE"/*.created-at; do
  [[ -e "$path" || -L "$path" ]] || continue
  slug="${path##*/}"
  case "$slug" in *.env) slug="${slug%.env}" ;; *.ports) slug="${slug%.ports}" ;; *.created-at) slug="${slug%.created-at}" ;; esac
  workspace_exists "$slug" && continue
  found=no
  for existing in "${orphan_names[@]+"${orphan_names[@]}"}"; do
    if [[ "$existing" == "$slug" ]]; then found=yes; break; fi
  done
  [[ "$found" == no ]] && orphan_names+=("$slug")
done
if [[ "$mode" == json ]]; then
  printf '%s\n' "${orphan_names[@]+"${orphan_names[@]}"}" | ruby -rjson -e 'items=STDIN.read.lines.map(&:strip).reject(&:empty?); puts JSON.pretty_generate({"orphaned_workspace_metadata"=>items,"destructive_actions_performed"=>false})'
else
  printf 'Gitwo / cleanup audit (read-only)\n'
  if [[ ${#orphan_names[@]} -eq 0 ]]; then
    printf '  No orphaned state or port metadata found\n'
  else
    for slug in "${orphan_names[@]}"; do
      printf '  ORPHAN  %s\n' "$slug"
      [[ ! -f "$GITWO_STATE/runtime/$slug.ports" ]] || printf '          Ports: reserved (review before gitwo clean --prune-ports=%s)\n' "$slug"
      [[ ! -f "$GITWO_STATE/$slug.env" ]] || printf '          State: retained for audit\n'
    done
  fi
  [[ ! -d "$GITWO_STATE/.create-lock" ]] || gitwo_warn 'Stale or active worktree creation lock exists; verify no new command is running before removing it manually.'
  printf '  No changes made. DBs and historical metadata are never automatically deleted.\n'
fi
