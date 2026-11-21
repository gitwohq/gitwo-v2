#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/_common.sh"
if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then
  printf 'Usage: gitwo checkout [WORKSPACE]\nChange to a worktree; omit WORKSPACE for automatic resolution/prompt.\n'
  exit 0
fi
[[ $# -le 1 ]] || gitwo_die 'Usage: checkout.sh [ENG-5303-feature-1 | ENG-5303-feature | ENG-5303 | /absolute/worktree/path]'
gitwo_check_source
gitwo_resolve_path "${1:-}"
