#!/usr/bin/env bash
# Read workspace-local logs, with no process startup or metadata mutation.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/_common.sh"
source "$GITWO_DIR/_runtime.sh"
usage() { cat <<'USAGE'
Usage: gitwo logs [WORKSPACE] [--service=supervisor|puma|rails|redis|sidekiq|all] [-f|--follow] [--lines=N]
  --service=supervisor  Managed bin/dev, Foreman or Rails launcher output
  --service=puma     Puma output captured by Gitwo (available from v4.13)
  --service=rails    Rails log/development.log
  --service=redis    Development and test Redis logs
  --service=sidekiq  Sidekiq log/sidekiq.log, if configured by the app
  --service=all      All available logs (default)
  -f, --follow       Follow file changes in real time
USAGE
}
selector='' service=all follow=no lines=80
for arg in "$@"; do
  case "$arg" in
    -h|--help) usage; exit 0 ;;
    -f|--follow) follow=yes ;;
    --service=*) service="${arg#--service=}" ;;
    --lines=*) lines="${arg#--lines=}" ;;
    -*) usage >&2; gitwo_die "Unknown logs option: $arg" ;;
    *) [[ -z "$selector" ]] || { usage >&2; exit 2; }; selector="$arg" ;;
  esac
done
case "$service" in supervisor|puma|rails|redis|sidekiq|all) ;; *) gitwo_die "Invalid log service: $service" ;; esac
[[ "$lines" =~ ^[1-9][0-9]{0,5}$ ]] || gitwo_die 'Expected --lines=positive-integer (max 6 digits)'
gitwo_check_source
target="$(gitwo_resolve_path "$selector")"
branch="$(git -C "$target" branch --show-current)"
gitwo_verify_target "$target" "$branch"
slug="$(basename "$target")"
root="$GITWO_STATE/runtime/$slug"
files=()
append_log() {
  local file="$1"
  [[ ! -L "$file" ]] || gitwo_die "Refusing symlink log file: $file"
  if [[ -f "$file" ]]; then files+=("$file"); fi
  return 0
}
if [[ "$service" == all || "$service" == supervisor ]]; then
  append_log "$root/supervisor.log"
fi
if [[ "$service" == all || "$service" == puma ]]; then
  append_log "$root/puma.log"
fi
if [[ "$service" == all || "$service" == rails ]]; then
  append_log "$target/log/development.log"
fi
if [[ "$service" == all || "$service" == sidekiq ]]; then
  append_log "$root/sidekiq.log"
  append_log "$target/log/sidekiq.log"
fi
if [[ "$service" == all || "$service" == redis ]]; then
  append_log "$root/redis-development.log"
  append_log "$root/redis-test.log"
fi
if (( ${#files[@]} == 0 )); then
  gitwo_warn "No $service logs found for $slug"
  [[ "$service" == puma ]] && gitwo_log 'Puma output logging begins with the first gitwo up after this upgrade.'
  exit 0
fi
if [[ "$follow" == yes ]]; then
  tail -n "$lines" -f "${files[@]}"
else
  tail -n "$lines" "${files[@]}"
fi
