#!/usr/bin/env bash
set -euo pipefail
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
for script in "$here"/*.sh "$here"/adapters/*.sh; do bash -n "$script"; done
for script in "$here"/*.rb; do ruby -c "$script" >/dev/null; done
"$here/test-universal.sh"
bash "$here/test-freeform.sh"
"$here/test-providers.sh"
bash "$here/test-team-onboard.sh"
bash "$here/test-scopes.sh"
"$here/test-testing.sh"
bash "$here/test-launcher.sh"
ruby "$here/test-frontend-detection.rb"
"$here/test-workspace-env.sh"
bash "$here/test-application-env.sh"
"$here/test-rails-config.sh"
bash "$here/test-rails-standard.sh"
"$here/test-services.sh"
"$here/test-security.sh"
printf '[PASS] Gitwo v4.21 static and isolated integration regression suite\n'
