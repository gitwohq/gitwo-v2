#!/usr/bin/env bash
# Select the application's existing development launcher without executing it.
# This adapter is also invoked after Portless assigns PORT to the child process.

gitwo_launcher_detect() {
  local root="$1" requested="${2:-auto}" procfile has_dev=no
  procfile="$root/Procfile.dev"
  [[ "$requested" == auto || "$requested" == rails || "$requested" == bin-dev ||
     "$requested" == foreman || "$requested" == overmind ]] ||
    { printf 'Unsupported launcher: %s\n' "$requested" >&2; return 2; }

  # Symlinked launch definitions can redirect outside the selected worktree.
  [[ ! -L "$root/bin/dev" && ! -L "$procfile" ]] ||
    { printf 'Refusing symlinked development launcher or Procfile.dev\n' >&2; return 1; }
  [[ ! -e "$root/bin/dev" || -f "$root/bin/dev" ]] ||
    { printf 'Invalid bin/dev: expected a regular file\n' >&2; return 1; }
  [[ ! -e "$procfile" || -f "$procfile" ]] ||
    { printf 'Invalid Procfile.dev: expected a regular file\n' >&2; return 1; }

  if [[ -f "$root/bin/dev" ]]; then
    [[ -x "$root/bin/dev" ]] ||
      { printf 'bin/dev exists but is not executable\n' >&2; return 1; }
    has_dev=yes
  fi

  if [[ "$requested" == auto ]]; then
    if [[ "$has_dev" == yes ]]; then
      requested=bin-dev
    elif [[ -f "$procfile" ]]; then
      if command -v overmind >/dev/null 2>&1; then
        requested=overmind
      elif command -v foreman >/dev/null 2>&1; then
        requested=foreman
      else
        printf 'Procfile.dev detected but neither Overmind nor Foreman is installed; install a manager, add bin/dev, or explicitly use --launcher=rails\n' >&2
        return 1
      fi
    else
      requested=rails
    fi
  fi

  if [[ "$requested" == bin-dev && "$has_dev" != yes ]]; then
    printf 'Selected bin-dev but no executable bin/dev found\n' >&2
    return 1
  fi
  if [[ "$requested" == foreman || "$requested" == overmind ]]; then
    [[ -f "$procfile" ]] ||
      { printf 'Selected process manager but Procfile.dev is absent\n' >&2; return 1; }
    grep -Eq '^[[:space:]]*web[[:space:]]*:' "$procfile" ||
      { printf 'Procfile.dev has no web process for Portless routing\n' >&2; return 1; }
    command -v "$requested" >/dev/null 2>&1 ||
      { printf 'Missing development process manager: %s\n' "$requested" >&2; return 1; }
  fi
  printf '%s\n' "$requested"
}

gitwo_launcher_exec() {
  local launcher="$1"
  shift
  case "$launcher" in
    rails) exec bundle exec rails server -b 127.0.0.1 "$@" ;;
    bin-dev) exec ./bin/dev "$@" ;;
    foreman)
      [[ "${PORT:-}" =~ ^[0-9]{2,5}$ ]] || { echo 'Foreman requires a valid PORT' >&2; return 1; }
      exec foreman start -f Procfile.dev -p "$PORT" "$@"
      ;;
    overmind)
      [[ "${PORT:-}" =~ ^[0-9]{2,5}$ ]] || { echo 'Overmind requires a valid PORT' >&2; return 1; }
      exec overmind start -f Procfile.dev -p "$PORT" "$@"
      ;;
    *) printf 'Unsupported launcher: %s\n' "$launcher" >&2; return 2 ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  [[ "$#" -ge 2 && "$1" == exec ]] || { printf 'Internal Gitwo launcher only\n' >&2; exit 2; }
  shift
  gitwo_launcher_exec "$@"
fi
