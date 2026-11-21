#!/usr/bin/env bash
# Resolve a user-supplied dump without leaving the local project dumps directory.
# Intended to be sourced by setup.sh, after _common.sh.

gitwo_dump_resolve() {
  local request="$1" root="$GITWO_ROOT/$GITWO_DUMPS_DIR" canonical_root candidate resolved
  local -a matches=()
  [[ -n "$request" ]] || gitwo_die '--dump requires a non-empty path'
  [[ -d "$root" && ! -L "$root" ]] || gitwo_die "Missing dumps directory: $root. Create it and place a sanitized pg_dump archive inside."
  canonical_root="$(cd "$root" && pwd -P)"
  if [[ "$request" == /* ]]; then
    candidate="$request"
  else
    candidate="$root/${request#"$GITWO_DUMPS_DIR"/}"
  fi
  if [[ -d "$candidate" ]]; then
    local folder
    folder="$(cd "$candidate" && pwd -P)" || gitwo_die "Cannot resolve dump folder: $candidate"
    [[ "$folder" == "$canonical_root" || "$folder" == "$canonical_root/"* ]] || gitwo_die 'Dump folder must be inside the configured dumps directory'
    for resolved in "$folder"/*.dump "$folder"/*.backup "$folder"/*.tar; do
      [[ -f "$resolved" ]] && matches+=("$resolved")
    done
    [[ ${#matches[@]} -eq 1 ]] || gitwo_die "Expected exactly one .dump/.backup/.tar archive in $folder, found ${#matches[@]}. Specify a filename."
    candidate="${matches[0]}"
  fi
  [[ -f "$candidate" && -r "$candidate" ]] || gitwo_die "Dump file does not exist or is unreadable: $candidate"
  resolved="$(ruby -e 'print File.realpath(ARGV.fetch(0))' "$candidate")" || gitwo_die "Cannot resolve dump path: $candidate"
  [[ "$resolved" == "$canonical_root/"* ]] || gitwo_die 'Dump file must be inside the configured dumps directory'
  case "$resolved" in *.dump|*.backup|*.tar) ;; *) gitwo_die "Expected a pg_restore archive (.dump, .backup, .tar), not: $resolved" ;; esac
  [[ -s "$resolved" ]] || gitwo_die "Dump archive is empty: $resolved"
  gitwo_need pg_restore
  pg_restore --list "$resolved" >/dev/null 2>&1 || gitwo_die "Invalid PostgreSQL archive: $resolved (expected pg_dump -Fc or -Ft)"
  printf '%s\n' "$resolved"
}
