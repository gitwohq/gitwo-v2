#!/usr/bin/env bash
set -euo pipefail
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
for script in "$here"/*.sh "$here"/adapters/*.sh; do bash -n "$script"; done
for script in "$here"/*.rb; do ruby -c "$script" >/dev/null; done
"$here/test-universal.sh"
"$here/test-providers.sh"
"$here/test-testing.sh"
"$here/test-workspace-env.sh"
"$here/test-security.sh"
printf '[PASS] Gitwo v4.21 static and isolated integration regression suite\n'
