#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/_common.sh"
source "$GITWO_DIR/jira-env.sh"

if [[ $# -ne 1 || "${1:-}" == "--help" ]]; then
  printf 'Usage: jira-test.sh <ENG-42|JIRA_URL>\n' >&2
  exit 2
fi

gitwo_need ruby
# Render Jira details via the shared issue resolver to avoid a second API call.
( gitwo_load_jira_env && ruby "$GITWO_DIR/issue.rb" describe "$1" )
