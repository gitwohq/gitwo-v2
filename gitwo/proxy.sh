#!/usr/bin/env bash
# Explicit, workspace-owned Portless HTTPS aliases for standard Rails commands.
set -euo pipefail
source "$(cd -- "$(dirname -- "$0")" && pwd -P)/_common.sh"
source "$GITWO_DIR/_runtime.sh"
[[ $# -ge 1 && $# -le 2 ]] || { echo 'Usage: gitwo workspace proxy <register|unregister|status> [WORKSPACE]' >&2; exit 2; }
action="$1"
case "$action" in register|unregister|status) ;; *) gitwo_die 'Expected register, unregister or status' ;; esac
[[ "$GITWO_PROXY" == portless ]] || gitwo_die 'Set runtime.proxy: portless before registering a native Rails HTTPS route'
gitwo_need portless
selector=''
[[ $# -eq 1 ]] || selector="$2"
gitwo_check_source
target="$(gitwo_resolve_path "$selector")"
branch="$(git -C "$target" branch --show-current)"
gitwo_verify_target "$target" "$branch"
gitwo_validate_workspace_identity "$target" "$branch"
gitwo_load_state "$target"
gitwo_runtime_existing_load "$target" || gitwo_die 'Run workspace env init before registering Portless'
name="$(gitwo_web_name "$target")"
hostname="$name.localhost"
port="$WEB_PORT"
marker="$GITWO_STATE/runtime/$(basename "$target").portless-alias"
[[ ! -L "$marker" && ( ! -e "$marker" || -f "$marker" ) ]] || gitwo_die 'Unsafe Portless marker'
record=''
[[ ! -f "$marker" ]] || record="$(cat "$marker")"
[[ -z "$record" || "$record" == "$name $port" ]] || gitwo_die 'Portless marker disagrees with workspace identity'

# Inspect the public Portless JSON CLI, never Portless internal state files.
route() {
  portless list --json | ruby -rjson -e '
    data = JSON.parse(STDIN.read)
    abort "Portless list must be an array" unless data.is_a?(Array)
    found = data.select { |row| row.is_a?(Hash) && row["hostname"] == ARGV.fetch(0) }
    abort "Ambiguous Portless alias" if found.size > 1
    if (entry = found.first)
      puts "#{entry["port"]}:#{entry["alias"] == true ? "alias" : "foreign"}"
    end
  ' "$hostname"
}
case "$action" in
  status)
    actual="$(route)" || gitwo_die 'Cannot inspect Portless routes'
    if [[ -z "$actual" ]]; then
      echo "No route for $hostname"
    elif [[ "$actual" == "$port:alias" && -n "$record" ]]; then
      echo "https://$hostname -> 127.0.0.1:$port (Gitwo-owned)"
    else
      gitwo_die "Portless route not owned by Gitwo: $hostname ($actual)"
    fi
    ;;
  register)
    gitwo_need node
    major="$(node -p 'Number(process.versions.node.split(".")[0])')"
    [[ "$major" =~ ^[0-9]+$ && "$major" -ge 24 ]] || gitwo_die 'Portless requires Node.js >= 24'
    portless proxy start --https
    actual="$(route)" || gitwo_die 'Cannot inspect Portless routes'
    if [[ -n "$actual" ]]; then
      [[ "$actual" == "$port:alias" && -n "$record" ]] || gitwo_die "Refusing to replace existing Portless route: $hostname"
    else
      portless alias "$name" "$port" || gitwo_die 'Could not register Portless alias'
      [[ "$(route)" == "$port:alias" ]] || gitwo_die 'Portless alias does not point to expected port'
      (umask 077; set -C; printf '%s %s\n' "$name" "$port" > "$marker") || gitwo_die 'Portless marker already exists'
    fi
    gitwo_ok "HTTPS route ready: https://$hostname (start native bin/rails server)"
    ;;
  unregister)
    [[ -n "$record" ]] || gitwo_die 'No Gitwo ownership marker; refusing alias removal'
    actual="$(route)" || gitwo_die 'Cannot inspect Portless routes'
    [[ -z "$actual" || "$actual" == "$port:alias" ]] || gitwo_die 'Refusing to remove a foreign Portless route'
    if [[ -n "$actual" ]]; then portless alias --remove "$name" || gitwo_die 'Could not remove Portless alias'; fi
    rm -- "$marker"
    gitwo_ok "Removed Gitwo-owned alias: $hostname"
    ;;
esac
