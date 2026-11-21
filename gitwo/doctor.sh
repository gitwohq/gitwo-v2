#!/usr/bin/env bash
# Installation checks can run outside any project; project diagnostics are opt-in.
set -euo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then
  echo 'Usage: gitwo doctor [--deps]'
  exit 0
fi
[[ $# -eq 0 || ( $# -eq 1 && "$1" == --deps ) ]] || { echo 'Usage: gitwo doctor [--deps]' >&2; exit 2; }
required=( _common.sh _runtime.sh _lifecycle.sh _prepare.sh _dumps.sh _ui.sh
  config.rb config.sh help.sh onboard.rb project.rb detect.rb detect.sh
  new.sh checkout.sh setup.sh run.sh down.sh logs.sh remove.sh init.sh redis.sh
  open.sh env.sh dump.sh clean.sh repair.sh list.sh baseline.sh
  provider.rb provider-env.sh issue.rb jira-env.sh jira-init.sh jira-test.sh
  _adapter.sh adapters/rails-standard.sh adapters/rails-webpack.sh shell.zsh VERSION )
fail=0
for item in "${required[@]}"; do
  if [[ ! -s "$root/$item" ]]; then
    printf '[MISSING] %s\n' "$item" >&2
    fail=1
  fi
done
(( fail == 0 )) || exit 1
printf '[OK] %s required Gitwo components present\n' "${#required[@]}"
if git -C "$PWD" rev-parse --show-toplevel >/dev/null 2>&1 || [[ -n "${GITWO_PROJECT_ROOT:-}" ]]; then
  source "$root/_common.sh"
  printf '[OK] Project: %s\n' "$GITWO_SOURCE"
  printf '[OK] Workspace root: %s\n' "$GITWO_ROOT"
  printf '[OK] State directory: %s\n' "$GITWO_STATE"
  if [[ -f "$GITWO_CONFIG_FILE" ]]; then
    ruby "$root/config.rb" validate "$GITWO_CONFIG_FILE"
  else
    printf '[INFO] No gitwo.yml; run gitwo init\n'
  fi
else
  printf '[INFO] No project selected; run from a Git checkout\n'
fi
if [[ "${1:-}" == --deps ]]; then
  missing=0
  for binary in git ruby mise node psql createdb pg_dump pg_restore redis-server redis-cli lsof; do
    if command -v "$binary" >/dev/null 2>&1; then
      printf '[OK] %s\n' "$binary"
    else
      printf '[MISSING] %s\n' "$binary" >&2
      missing=1
    fi
  done
  if [[ "${GITWO_PROXY:-none}" == portless ]]; then
    if ! command -v portless >/dev/null 2>&1; then
      printf '[MISSING] portless (selected by project config)\n' >&2
      missing=1
    elif [[ -d "$HOME/.portless/ca.pem" ]]; then
      printf '[ERROR] Portless CA path is a directory, expected a certificate file\n' >&2
      missing=1
    fi
  fi
  (( missing == 0 )) || exit 1
fi
