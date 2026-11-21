#!/usr/bin/env bash
set -euo pipefail
# Create or edit a private local Jira config without placing credentials in Git.
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
file="${GITWO_JIRA_ENV_FILE:-}"
if [[ -z "$file" ]]; then
  file="${XDG_CONFIG_HOME:-$HOME/.config}/gitwo/jira.env"
fi
case "${1:-}" in
  ''|--no-edit) ;;
  -h|--help) printf 'Usage: jira-init.sh [--no-edit]\n'; exit 0 ;;
  *) printf 'ERROR Unknown option: %s\n' "$1" >&2; exit 2 ;;
esac
[[ $# -le 1 ]] || { printf 'ERROR Too many arguments\n' >&2; exit 2; }
mkdir -p "$(dirname -- "$file")"
chmod 700 "$(dirname -- "$file")"
if [[ -e "$file" || -L "$file" ]]; then
  [[ ! -L "$file" && -f "$file" ]] || { printf 'ERROR Jira config must be a normal file\n' >&2; exit 2; }
  printf 'Existing Jira config kept: %s\n' "$file"
else
  (umask 077; cp "$root/jira.example.env" "$file")
  printf 'Created private Jira config: %s\n' "$file"
fi
chmod 600 "$file"
if [[ "${1:-}" != --no-edit && -t 0 && -t 1 ]]; then
  editor="${VISUAL:-${EDITOR:-nano}}"
  # The editor must be an executable name/path, not arbitrary shell code.
  command -v "$editor" >/dev/null 2>&1 || { printf 'ERROR Editor not found: %s\n' "$editor" >&2; exit 2; }
  "$editor" "$file"
else
  printf 'Edit: nano %s\n' "$file"
fi
