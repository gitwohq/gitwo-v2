#!/usr/bin/env bash
# Return the configured permanent source checkout path for the shell wrapper.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/_common.sh"
[[ $# -eq 0 ]] || gitwo_die 'Usage: gitwo base'
gitwo_check_source
printf '%s\n' "$GITWO_SOURCE"
