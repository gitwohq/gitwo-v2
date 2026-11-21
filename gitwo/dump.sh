#!/usr/bin/env bash
# Safe local PostgreSQL dumps. Backups can contain confidential customer data.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/_common.sh"
source "$GITWO_DIR/_dumps.sh"
usage() { cat <<'USAGE'
Usage: gitwo dump <list|inspect|create> [arguments]
  gitwo dump list
  gitwo dump inspect PATH
  gitwo dump create [WORKSPACE] [--name=LABEL]
Create only from an owned LOCAL development DB. Dumps are private and may contain sensitive data.
Only use sanitized dumps when sharing or restoring in less-trusted environments.
USAGE
}
[[ $# -gt 0 ]] || { usage; exit 2; }
action="$1"; shift
case "$action" in -h|--help) usage; exit 0 ;; esac
root="$GITWO_ROOT/$GITWO_DUMPS_DIR"
[[ ! -L "$root" ]] || gitwo_die "Unsafe dumps symlink: $root"
case "$action" in
  list)
    [[ $# -eq 0 ]] || gitwo_die 'Usage: gitwo dump list'
    [[ -d "$root" ]] || { gitwo_warn "Dumps directory not present: $root"; exit 0; }
    (cd "$root" && find . -type f \( -name '*.dump' -o -name '*.backup' -o -name '*.tar' \) -print | LC_ALL=C sort)
    ;;
  inspect)
    [[ $# -eq 1 ]] || gitwo_die 'Usage: gitwo dump inspect PATH'
    file="$(gitwo_dump_resolve "$1")"
    printf 'Archive: %s\nSize:    %s bytes\n' "$file" "$(wc -c < "$file" | tr -d ' ')"
    pg_restore --list "$file"
    ;;
  create)
    selector='' label=''
    for arg in "$@"; do
      case "$arg" in
        --name=*) label="${arg#--name=}" ;;
        -h|--help) usage; exit 0 ;;
        -*) gitwo_die "Unknown dump create option: $arg" ;;
        *) [[ -z "$selector" ]] || gitwo_die 'Too many workspace selectors'; selector="$arg" ;;
      esac
    done
    [[ -z "$label" || "$label" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]{0,60}$ ]] || gitwo_die 'Dump name must be a single safe label'
    gitwo_need git; gitwo_need pg_dump; gitwo_need psql
    gitwo_check_source
    target="$(gitwo_resolve_path "$selector")"
    branch="$(git -C "$target" branch --show-current)"
    gitwo_verify_target "$target" "$branch"
    gitwo_validate_workspace_identity "$target" "$branch"
    slug="$(basename "$target")"
    gitwo_db_settings
    db="$(gitwo_expected_db_name "$target" development)"
    marker="$GITWO_STATE/${slug}.db-ready"
    state_file="$(gitwo_state_path "$target")"
    [[ -f "$marker" && ! -L "$marker" && -f "$state_file" && ! -L "$state_file" ]] || gitwo_die 'No trusted DB ownership metadata. Refusing backup.'
    gitwo_load_state "$target"
    [[ "$GITWO_DB_DEV" == "$db" && "$(cat "$marker")" == "$db" ]] || gitwo_die 'DB ownership mismatch'
    exists="$(gitwo_pg psql --no-psqlrc -w -d postgres -Atqc "SELECT 1 FROM pg_database WHERE datname = '$db'" 2>/dev/null)" || gitwo_die 'Cannot inspect local PostgreSQL'
    [[ "$exists" == 1 ]] || gitwo_die 'Owned development DB is missing'
    [[ -d "$root" || ! -e "$root" ]] || gitwo_die "Unsafe dumps path: $root"
    mkdir -p "$root"
    chmod 700 "$root"
    day="$(date -u '+%Y-%m-%d')"
    folder="$root/$day"
    [[ ! -L "$folder" ]] || gitwo_die "Unsafe dump folder symlink: $folder"
    (umask 077; mkdir -p "$folder")
    [[ -d "$folder" && ! -L "$folder" ]] || gitwo_die 'Invalid dump folder'
    chmod 700 "$folder"
    [[ -n "$label" ]] || label="${slug}-$(date -u '+%H%M%S')"
    final="$folder/$label.dump"
    [[ ! -e "$final" && ! -L "$final" ]] || gitwo_die "Dump already exists: $final"
    tmp="$(umask 077; mktemp "$folder/.gitwo-export.XXXXXX")" || gitwo_die 'Cannot create private temporary archive'
    trap 'rm -f -- "$tmp"' EXIT
    gitwo_warn 'This archive may contain production/customer secrets. Do not share without sanitizing.'
    gitwo_pg pg_dump -Fc --no-owner --no-acl -f "$tmp" "$db" || gitwo_die 'pg_dump failed; no final archive created'
    [[ -s "$tmp" ]] || gitwo_die 'pg_dump produced an empty archive'
    # Hard-link prevents overwriting even if another process created the destination.
    ln "$tmp" "$final" || gitwo_die 'Archive name is already taken'
    rm -f "$tmp"
    trap - EXIT
    chmod 600 "$final"
    printf '%s\n' "$final"
    ;;
  *) usage >&2; gitwo_die "Unknown dump action: $action" ;;
esac
