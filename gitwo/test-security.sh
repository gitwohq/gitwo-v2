#!/usr/bin/env bash
# Refuse executable state metadata and validate persisted ports as data.
set -euo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/gitwo-security.XXXXXXXX")"
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/project" "$tmp/state"
git -C "$tmp/project" init -q -b main
GITWO_PROJECT_ROOT="$tmp/project" GITWO_STATE="$tmp/state" GITWO_DB_PREFIX=fixture bash -c '
  set -euo pipefail
  source "$1/_common.sh"
  source "$1/_runtime.sh"
  workspace="$2/eng-42-feature"
  mkdir -p "$workspace"
  gitwo_write_state "$workspace" feature ENG-42
  gitwo_load_state "$workspace"
  [[ "$GITWO_PATH" == "$workspace" ]]
  file="$(gitwo_state_path "$workspace")"
  malicious="$2/executed"
  printf '\''GITWO_PATH=$(touch %s)\nGITWO_TYPE=feature\nGITWO_TICKET=ENG-42\nGITWO_DB_DEV=fixture_eng_42_feature_development\nGITWO_DB_TEST=fixture_eng_42_feature_test\n'\'' "$malicious" > "$file"
  if (gitwo_load_state "$workspace") >/dev/null 2>&1; then
    echo "Untrusted state command was accepted" >&2
    exit 1
  fi
  [[ ! -e "$malicious" ]] || { echo "State command executed" >&2; exit 1; }
  ports="$(_gitwo_runtime_ports_file "$workspace")"
  mkdir -p "$(dirname "$ports")"
  printf "REDIS_DEV_PORT=16380\nREDIS_TEST_PORT=19380\nWEB_PORT=12000\n" > "$ports"
  gitwo_runtime_existing_load "$workspace"
  [[ "$REDIS_DEV_PORT" == 16380 && "$WEB_PORT" == 12000 ]]
  printf '\''REDIS_DEV_PORT=16380\nREDIS_TEST_PORT=19380\nWEB_PORT=$(touch %s)\n'\'' "$malicious" > "$ports"
  if (gitwo_runtime_existing_load "$workspace") >/dev/null 2>&1; then
    echo "Untrusted port metadata accepted" >&2
    exit 1
  fi
  [[ ! -e "$malicious" ]] || { echo "Port command executed" >&2; exit 1; }
  printf "REDIS_DEV_PORT=16380\nREDIS_DEV_PORT=16381\nWEB_PORT=12000\n" > "$ports"
  if (gitwo_runtime_existing_load "$workspace") >/dev/null 2>&1; then
    echo "Duplicate Redis development key was accepted" >&2
    exit 1
  fi
  printf "REDIS_DEV_PORT=16380\nREDIS_TEST_PORT=19380\nWEB_PORT=99999\n" > "$ports"
  if (gitwo_runtime_existing_load "$workspace") >/dev/null 2>&1; then
    echo "Out-of-range workspace port was accepted" >&2
    exit 1
  fi
' bash "$root" "$tmp"
echo '[PASS] state and ports metadata reject executable payloads'
