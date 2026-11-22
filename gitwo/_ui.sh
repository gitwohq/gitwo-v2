#!/usr/bin/env bash
# Human-readable CLI output and private command logs; Bash 3.2 compatible.
# All presentation goes to stderr. Successful new.sh/checkout.sh stdout is only a path.

GITWO_VERBOSE="${GITWO_VERBOSE:-0}"
GITWO_LOG_FILE=''

_gitwo_ui_color() {
  case "$1" in
    muted) printf '%s' "${C_MUTED:-}" ;;
    cyan) printf '%s' "$C_CYAN" ;;
    green) printf '%s' "$C_GREEN" ;;
    yellow) printf '%s' "$C_YELLOW" ;;
    red) printf '%s' "$C_RED" ;;
    *) printf '%s' "$C_RESET" ;;
  esac
}

gitwo_ui_start() {
  local title="$1" issue="${2:-workspace}" stamp
  mkdir -p "$GITWO_STATE/logs"
  chmod 700 "$GITWO_STATE" "$GITWO_STATE/logs"
  stamp="$(date '+%Y%m%d-%H%M%S')"
  GITWO_LOG_FILE="$GITWO_STATE/logs/${issue}-${stamp}-$$.log"
  (umask 077; : > "$GITWO_LOG_FILE")
  printf '\n%s╭──────────────────────────────────────────────────────────╮%s\n' "$C_CYAN" "$C_RESET" >&2
  printf '%s│%s  gitwo  /  %-47.47s %s│%s\n' "$C_CYAN" "$C_RESET" "$title" "$C_CYAN" "$C_RESET" >&2
  printf '%s╰──────────────────────────────────────────────────────────╯%s\n' "$C_CYAN" "$C_RESET" >&2
}

gitwo_ui_section() {
  printf '\n%s%s%s\n' "$C_CYAN" "$1" "$C_RESET" >&2
}

gitwo_ui_meta() {
  printf '  %s%-12s%s %s\n' "${C_MUTED:-}" "$1" "$C_RESET" "$2" >&2
}

gitwo_ui_run() {
  local label="$1" started=$SECONDS code
  shift
  printf '  %s[..]%s %s\n' "$C_CYAN" "$C_RESET" "$label" >&2
  if [[ "$GITWO_VERBOSE" == 1 ]]; then
    if "$@" 2>&1 | tee -a "$GITWO_LOG_FILE" >&2; then
      printf '  %s[OK]%s %s %s(%ss)%s\n' "$C_GREEN" "$C_RESET" "$label" "${C_MUTED:-}" "$((SECONDS - started))" "$C_RESET" >&2
      return 0
    else
      code=$?
    fi
  else
    if "$@" >> "$GITWO_LOG_FILE" 2>&1; then
      printf '  %s[OK]%s %s %s(%ss)%s\n' "$C_GREEN" "$C_RESET" "$label" "${C_MUTED:-}" "$((SECONDS - started))" "$C_RESET" >&2
      return 0
    else
      code=$?
    fi
  fi
  # Both if-branches above failed. Preserve failure for the caller and show the exact log.
  printf '  %s[FAIL]%s %s\n' "$C_RED" "$C_RESET" "$label" >&2
  printf '\n  Recent output (%s):\n' "$GITWO_LOG_FILE" >&2
  tail -n 25 "$GITWO_LOG_FILE" >&2 || true
  return "${code:-1}"
}

gitwo_ui_note_warnings() {
  [[ -n "$GITWO_LOG_FILE" && -f "$GITWO_LOG_FILE" ]] || return 0
  if grep -Eq 'WARNING in |compiled with [1-9][0-9]* warnings|warning: ' "$GITWO_LOG_FILE"; then
    printf '  %s[WARN]%s Build emitted warnings (non-fatal). See %s\n' "$C_YELLOW" "$C_RESET" "$GITWO_LOG_FILE" >&2
  fi
}

gitwo_ui_done() {
  printf '\n%s[READY]%s %s\n' "$C_GREEN" "$C_RESET" "$1" >&2
  if [[ -n "$GITWO_LOG_FILE" ]]; then
    printf '  %sLog:%s %s\n' "${C_MUTED:-}" "$C_RESET" "$GITWO_LOG_FILE" >&2
  fi
}

gitwo_ui_created() {
  printf '\n%s[CREATED]%s %s\n' "$C_YELLOW" "$C_RESET" "$1" >&2
  if [[ -n "$GITWO_LOG_FILE" ]]; then
    printf '  %sLog:%s %s\n' "${C_MUTED:-}" "$C_RESET" "$GITWO_LOG_FILE" >&2
  fi
}
