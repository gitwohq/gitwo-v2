#!/usr/bin/env bash
# Open the current workspace URL without starting services or modifying state.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/_common.sh"
source "$GITWO_DIR/_runtime.sh"
selector='' print_only=no
for arg in "$@"; do
  case "$arg" in
    -h|--help) printf 'Usage: gitwo open [WORKSPACE] [--print]\nOpen the local workspace URL in a browser; --print does not open it.\n'; exit 0 ;;
    --print) print_only=yes ;;
    -*) gitwo_die "Unknown open option: $arg" ;;
    *) [[ -z "$selector" ]] || gitwo_die 'Only one workspace selector allowed'; selector="$arg" ;;
  esac
done
gitwo_check_source
target="$(gitwo_resolve_path "$selector")"
branch="$(git -C "$target" branch --show-current)"
gitwo_verify_target "$target" "$branch"
gitwo_validate_workspace_identity "$target" "$branch"
if [[ "${GITWO_PROXY:-portless}" == none ]]; then
  gitwo_runtime_existing_load "$target" || gitwo_die 'No assigned web port for direct mode; run gitwo up first'
  url="http://127.0.0.1:${WEB_PORT}"
else
  url="$(gitwo_web_url "$target")"
fi
if [[ "$print_only" == yes ]]; then printf '%s\n' "$url"; exit 0; fi
if command -v open >/dev/null 2>&1; then
  open "$url"
elif command -v xdg-open >/dev/null 2>&1; then
  xdg-open "$url"
else
  gitwo_die "Cannot open browser on this OS. URL: $url"
fi
printf '%s\n' "$url"
