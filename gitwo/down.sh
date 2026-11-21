#!/usr/bin/env bash
# Stop only the current workspace's verified Puma and Redis processes.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/_common.sh"
source "$GITWO_DIR/_runtime.sh"
source "$GITWO_DIR/_lifecycle.sh"
usage() { printf 'Usage: gitwo down [WORKSPACE]\nStop verified workspace Puma and both Redis instances; leave shared Portless proxy running.\n'; }
if [[ "${1:-}" == -h || "${1:-}" == --help ]]; then usage; exit 0; fi
[[ $# -le 1 ]] || { usage >&2; exit 2; }
gitwo_need git
gitwo_check_source
target="$(gitwo_resolve_path "${1:-}")"
branch="$(git -C "$target" branch --show-current)"
gitwo_verify_target "$target" "$branch"
# Do not stop unknown processes based solely on an untrusted file.
gitwo_sidekiq_stop "$target" || gitwo_die "Could not stop Sidekiq safely"
gitwo_puma_stop "$target" || gitwo_die "Refusing to stop an unverified Puma process"
if gitwo_runtime_existing_load "$target"; then
  gitwo_need redis-cli
  gitwo_redis_stop "$target" development
  gitwo_redis_stop "$target" test
fi
gitwo_ok "Stopped managed services for $(basename "$target") (shared Portless proxy unchanged)"
gitwo_log 'Only verified Sidekiq processes within the selected workspace are stopped.'
