#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/_common.sh"
[[ "${1:-}" == refresh && $# -eq 1 ]] || gitwo_die 'Usage: baseline.sh refresh'

gitwo_need git; gitwo_need pg_dump
gitwo_check_source
gitwo_db_settings
src_db="${GITWO_BASELINE_DB:?Set GITWO_BASELINE_DB to an explicit local source database}"
[[ "$src_db" =~ ^[a-zA-Z][a-zA-Z0-9_]+$ ]] || gitwo_die 'Invalid baseline DB name'
mkdir -p "$GITWO_STATE"; chmod 700 "$GITWO_STATE"
output="$GITWO_STATE/baseline.dump"
partial="$GITWO_STATE/baseline.dump.partial.$$"
trap 'rm -f "$partial"' EXIT
gitwo_warn 'Only snapshot trusted, sanitized local data. Never commit or upload this dump.'
gitwo_log "Snapshot $src_db -> $output"
( umask 077; gitwo_pg pg_dump --format=custom --no-owner --no-acl --file "$partial" "$src_db" )
mv "$partial" "$output"
chmod 600 "$output"
gitwo_ok "Saved local baseline dump: $output"
