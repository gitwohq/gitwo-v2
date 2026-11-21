#!/usr/bin/env bash
# Load provider credentials from 0600 local files; do not source file contents.
_gitwo_provider_credentials() {
  local kind="$1" profile="${GITWO_CREDENTIAL_PROFILE:-default}" file
  [[ "$profile" =~ ^[a-z][a-z0-9_-]{0,31}$ ]] || { echo 'ERROR: Unsafe credential profile' >&2; return 2; }
  file="${XDG_CONFIG_HOME:-$HOME/.config}/gitwo/credentials/${profile}/${kind}.env"
  if [[ ! -f "$file" && "$profile" == default ]]; then
    file="${XDG_CONFIG_HOME:-$HOME/.config}/gitwo/${kind}.env"
  fi
  local line key value mode
  [[ -f "$file" ]] || return 0
  [[ ! -L "$file" ]] || { printf 'ERROR: Symlinked credential file: %s\n' "$file" >&2; return 2; }
  mode="$(stat -c %a "$file" 2>/dev/null || true)"
  if [[ ! "$mode" =~ ^[0-7]{3,4}$ ]]; then
    mode="$(stat -f %Lp "$file" 2>/dev/null || true)"
  fi
  [[ "$mode" =~ ^[0-7]{3,4}$ ]] || { echo 'ERROR: Cannot determine credential file permissions' >&2; return 2; }
  (( (8#$mode & 077) == 0 )) || { printf 'ERROR: Credentials are group/world-readable: %s\n' "$file" >&2; return 2; }
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
    [[ "$line" =~ ^([A-Z_]+)=(.*)$ ]] || { printf 'ERROR: Invalid credential record\n' >&2; return 2; }
    key="${BASH_REMATCH[1]}"; value="${BASH_REMATCH[2]}"
    case "$kind:$key" in
      jira:JIRA_EMAIL|jira:JIRA_API_TOKEN|jira:JIRA_BEARER_TOKEN|jira:JIRA_BASE_URL|jira:JIRA_API_BASE_URL|jira:JIRA_CLOUD_ID|linear:LINEAR_API_KEY) ;;
      *) printf 'ERROR: Unexpected credential key: %s\n' "$key" >&2; return 2 ;;
    esac
    [[ -n "${!key+x}" ]] || export "$key=$value"
  done < "$file"
}
gitwo_provider_resolve() (
  case "${GITWO_ISSUE_PROVIDER:-none}" in
    jira)
      [[ -n "${JIRA_BASE_URL:-}" || -z "${GITWO_ISSUE_URL:-}" ]] || export JIRA_BASE_URL="$GITWO_ISSUE_URL"
      _gitwo_provider_credentials jira || return $?
      ruby "$GITWO_DIR/provider.rb" "$@" ;;
    linear)
      _gitwo_provider_credentials linear || return $?
      ruby "$GITWO_DIR/provider.rb" "$@" ;;
    github|none) ruby "$GITWO_DIR/provider.rb" "$@" ;;
    *) printf 'ERROR: Unsupported provider: %s\n' "$GITWO_ISSUE_PROVIDER" >&2; return 2 ;;
  esac
)
