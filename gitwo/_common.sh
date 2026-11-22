#!/usr/bin/env bash
# Shared helpers for installed Gitwo workspace scripts. Bash 3.2-compatible.
set -euo pipefail

export GIT_PAGER=cat
export PAGER=cat
export GIT_TERMINAL_PROMPT=0
export GIT_OPTIONAL_LOCKS=1

GITWO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# The launcher is installed globally; the project is selected from the current
# checkout or GITWO_PROJECT_ROOT. No state is kept in the application checkout.
# Reject ambiguous invocations instead of selecting a random repository.
_gitwo_detect_source() {
  local at="${GITWO_PROJECT_ROOT:-$PWD}" root main
  root="$(git -C "$at" rev-parse --show-toplevel 2>/dev/null)" || return 1
  main="$(git -C "$root" worktree list --porcelain | sed -n 's/^worktree //p' | head -1)"
  [[ -n "$main" && -d "$main" && ! -L "$main" ]] || return 1
  (cd "$main" && pwd -P)
}
GITWO_SOURCE="$(_gitwo_detect_source)" || {
  printf 'gitwo: project not found; run inside a Git checkout or set GITWO_PROJECT_ROOT=/path/to/repo\n' >&2
  exit 2
}
GITWO_PROJECT_SOURCE="$(basename "$GITWO_SOURCE")"
[[ "$GITWO_PROJECT_SOURCE" =~ ^[a-zA-Z][a-zA-Z0-9_-]*$ ]] || { echo 'gitwo: invalid project checkout basename' >&2; exit 2; }
GITWO_PROJECT_ID="$(printf '%s' "$GITWO_SOURCE" | ruby -rdigest -e 'print Digest::SHA256.hexdigest(STDIN.read)[0,16]')"
GITWO_GLOBAL_STATE_ROOT="${GITWO_GLOBAL_STATE_ROOT:-$HOME/.local/state/gitwo}"
GITWO_STATE="${GITWO_STATE:-$GITWO_GLOBAL_STATE_ROOT/projects/$GITWO_PROJECT_ID}"
GITWO_ROOT="${GITWO_WORKSPACES_ROOT:-$(dirname "$GITWO_SOURCE")/.gitwo-workspaces/$GITWO_PROJECT_SOURCE}"
# Resolve the personal XDG config first, then an existing team config.
# GITWO_SCOPE selects the mode explicitly; GITWO_CONFIG_FILE remains a manual override.
if [[ -z "${GITWO_CONFIG_FILE:-}" ]]; then
  GITWO_CONFIG_FILE="$(ruby "$GITWO_DIR/config-location.rb" active "$GITWO_SOURCE")" ||
    { printf 'gitwo: could not resolve local/team configuration\n' >&2; exit 2; }
fi
export GITWO_CONFIG_FILE GITWO_SOURCE GITWO_PROJECT_SOURCE GITWO_PROJECT_ID GITWO_STATE GITWO_ROOT GITWO_GLOBAL_STATE_ROOT

C_RESET='' C_CYAN='' C_GREEN='' C_YELLOW='' C_RED='' C_MUTED=''
if [[ -t 2 && -z "${NO_COLOR+x}" && "${TERM:-}" != dumb ]]; then
  C_RESET=$'\033[0m'; C_CYAN=$'\033[36m'; C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'; C_MUTED=$'\033[2m'
fi
gitwo_log()  { printf '  %s[INFO]%s %s\n' "$C_CYAN" "$C_RESET" "$*" >&2; }
gitwo_ok()   { printf '  %s[OK]%s %s\n' "$C_GREEN" "$C_RESET" "$*" >&2; }
gitwo_warn() { printf '  %s[WARN]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
gitwo_die()  { printf '  %s[ERROR]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }
source "$GITWO_DIR/_ui.sh"
# Optional, strictly validated project settings. An explicit process ENV wins.
# Bash 3.2-compatible and never evaluates YAML or shell snippets as code.
gitwo_config_load() {
  local settings key value
  [[ "$GITWO_CONFIG_FILE" == /* ]] || gitwo_die 'GITWO_CONFIG_FILE must be an absolute path'
  [[ -e "$GITWO_CONFIG_FILE" || -L "$GITWO_CONFIG_FILE" ]] || return 0
  [[ -f "$GITWO_CONFIG_FILE" && ! -L "$GITWO_CONFIG_FILE" ]] || gitwo_die "Unsafe config file: $GITWO_CONFIG_FILE"
  command -v ruby >/dev/null 2>&1 || gitwo_die 'Ruby required to parse config.yml'
  settings="$(ruby "$GITWO_DIR/config.rb" export "$GITWO_CONFIG_FILE")" || gitwo_die "Invalid config file: $GITWO_CONFIG_FILE"
  [[ -n "$settings" ]] || return 0
  while IFS='=' read -r key value; do
    case "$key" in
      GITWO_ADAPTER|GITWO_PROJECT_SOURCE|GITWO_BASE_BRANCH|GITWO_DUMPS_DIR|GITWO_DB_PREFIX|GITWO_FEATURE_BASE|GITWO_HOTFIX_BASE|GITWO_DB_HOST|GITWO_DB_PORT|GITWO_DB_USER|GITWO_PROXY|GITWO_DOMAIN|GITWO_GIT_WORKFLOW|GITWO_ISSUE_PROVIDER|GITWO_ISSUE_URL|GITWO_CREDENTIAL_PROFILE|GITWO_FRAMEWORK|GITWO_HAS_SIDEKIQ|GITWO_HAS_REDIS|GITWO_BOOTSTRAP|GITWO_SERVICES_BACKEND) ;;
      *) gitwo_die "Invalid config key: $key" ;;
    esac
    if [[ -z "${!key+x}" ]]; then
      export "$key=$value"
    fi
  done <<< "$settings"
}
gitwo_config_load
GITWO_FEATURE_BASE="${GITWO_FEATURE_BASE:-origin/$(git -C "$GITWO_SOURCE" branch --show-current)}"
GITWO_HOTFIX_BASE="${GITWO_HOTFIX_BASE:-$GITWO_FEATURE_BASE}"
# All configurable resource names are one safe segment. Never resolve a user-supplied
# project path outside the selected parent or load arbitrary adapter code.
GITWO_CREDENTIAL_PROFILE="${GITWO_CREDENTIAL_PROFILE:-default}"
[[ "$GITWO_CREDENTIAL_PROFILE" =~ ^[a-z][a-z0-9_-]{0,31}$ ]] || gitwo_die "Invalid credential profile"
GITWO_ISSUE_PROVIDER="${GITWO_ISSUE_PROVIDER:-none}"
export GITWO_ISSUE_PROVIDER GITWO_ISSUE_URL GITWO_CREDENTIAL_PROFILE
GITWO_BOOTSTRAP="${GITWO_BOOTSTRAP:-schema}"
GITWO_PROXY="${GITWO_PROXY:-none}"
GITWO_SERVICES_BACKEND="${GITWO_SERVICES_BACKEND:-native}"
case "$GITWO_SERVICES_BACKEND" in native|compose) ;; *) gitwo_die "Unsupported services backend: $GITWO_SERVICES_BACKEND" ;; esac
export GITWO_SERVICES_BACKEND
GITWO_ADAPTER="${GITWO_ADAPTER:-rails-standard}"
GITWO_PROJECT_SOURCE="${GITWO_PROJECT_SOURCE:-$(basename "$GITWO_SOURCE")}"
GITWO_BASE_BRANCH="${GITWO_BASE_BRANCH:-$(git -C "$GITWO_SOURCE" branch --show-current)}"
GITWO_DB_PREFIX="${GITWO_DB_PREFIX:-$(printf "%s" "$GITWO_PROJECT_SOURCE" | tr "[:upper:]-" "[:lower:]_" | cut -c1-20)}"
GITWO_DUMPS_DIR="${GITWO_DUMPS_DIR:-dumps}"
# project.source is a stable logical team label, not the developer's local clone folder.
# Workspace paths and state remain rooted in the canonical local checkout path.
case "$GITWO_ADAPTER" in rails-webpack|rails-standard) ;; *) gitwo_die "Unknown project adapter: $GITWO_ADAPTER" ;; esac
[[ "$GITWO_PROJECT_SOURCE" =~ ^[a-zA-Z][a-zA-Z0-9_-]*$ ]] || gitwo_die 'Unsafe project.source name'
[[ "$GITWO_BASE_BRANCH" =~ ^[a-zA-Z][a-zA-Z0-9._-]*$ && "$GITWO_BASE_BRANCH" != *..* && "$GITWO_BASE_BRANCH" != *.lock ]] || gitwo_die 'Unsafe project.base_branch'
[[ "$GITWO_DB_PREFIX" =~ ^[a-z][a-z0-9_]{0,20}$ ]] || gitwo_die 'Unsafe database.prefix'
[[ "$GITWO_DUMPS_DIR" =~ ^[a-zA-Z][a-zA-Z0-9_-]*$ ]] || gitwo_die 'Unsafe storage.dumps_directory'
export GITWO_SOURCE GITWO_ADAPTER GITWO_PROJECT_SOURCE GITWO_BASE_BRANCH GITWO_DB_PREFIX GITWO_DUMPS_DIR
gitwo_need() { command -v "$1" >/dev/null 2>&1 || gitwo_die "Missing command: $1"; }
gitwo_check_source() {
  [[ -d "$GITWO_SOURCE" ]] || gitwo_die "Missing base repository: $GITWO_SOURCE"
  local actual
  actual="$(git -C "$GITWO_SOURCE" rev-parse --show-toplevel 2>/dev/null)" || gitwo_die "Not a Git repository: $GITWO_SOURCE"
  [[ "$actual" == "$GITWO_SOURCE" ]] || gitwo_die "Unexpected repository root: $actual"
  [[ "$(git -C "$GITWO_SOURCE" branch --show-current)" == "$GITWO_BASE_BRANCH" ]] || gitwo_die "Base repository must stay on $GITWO_BASE_BRANCH"
}
gitwo_validate_ticket() {
  [[ "$1" =~ ^[A-Z][A-Z0-9]{1,14}-[0-9]{1,10}$ ]] || gitwo_die "Invalid ticket ID: $1 (expected ENG-42)"
}
gitwo_branch_type() {
  if [[ "$1" =~ ^experiment/develop-[1-9][0-9]*$ ]]; then
    printf 'develop\n'
  else
    printf '%s\n' "${1%%/*}"
  fi
}
gitwo_issue_key_from_branch() {
  if [[ "$1" =~ ^experiment/develop-([1-9][0-9]*)$ ]]; then
    printf 'DEVELOP-%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi
  local suffix="${1#*/}" key
  if [[ "$suffix" =~ ^([A-Z][A-Z0-9]{1,14}-[0-9]{1,10})(-|$) ]]; then
    key="${BASH_REMATCH[1]}"
    gitwo_validate_ticket "$key"
    printf "%s\n" "$key"
  elif [[ "$1" =~ ^feature/([a-z][a-z0-9]*(-[a-z0-9]+)*)-([1-9][0-9]*)$ ]]; then
    # Local feature workspaces identify their work item by a normalized name
    # plus a sequential instance. No issue tracker is involved.
    printf '%s\n' "${1#feature/}"
  else
    gitwo_die "Cannot extract issue key from branch: $1"
  fi
}
gitwo_matches_issue_branch() {
  local branch="$1" ticket="$2" prefix
  case "$branch" in feature/*|bugfix/*|hotfix/*) ;; *) return 1 ;; esac
  prefix="${branch#*/}"
  [[ "$prefix" == "$ticket" || "$prefix" == "$ticket-"* ]]
}
gitwo_validate_type() {
  [[ "$1" == feature || "$1" == hotfix || "$1" == bugfix || "$1" == develop ]] || gitwo_die "Type must be feature, hotfix, bugfix, or develop"
}
gitwo_validate_feature_name() {
  [[ "$1" =~ ^[a-z][a-z0-9]*(-[a-z0-9]+)*$ && ${#1} -le 24 && "$1" != develop ]] ||
    gitwo_die 'Feature name must be a lowercase slug (letters/digits/hyphens, max 24 chars)'
}
# No Jira key is required for sequential development experiments.
gitwo_workspace_name() {
  if [[ "$1" == develop ]]; then
    [[ "$2" =~ ^DEVELOP-([1-9][0-9]*)$ ]] || gitwo_die "Invalid develop workspace key: $2"
    printf 'develop-%s\n' "${BASH_REMATCH[1]}"
  else
    gitwo_slug "$1" "$2"
  fi
}
gitwo_validate_workspace_identity() {
  local path="$1" branch="$2" type ticket name canonical
  name="$(basename "$path")"
  if [[ "$branch" =~ ^experiment/develop-([1-9][0-9]*)$ ]]; then
    [[ "$name" == "develop-${BASH_REMATCH[1]}" ]] || gitwo_die "Invalid develop workspace: $name ($branch)"
    return 0
  fi
  if [[ "$branch" =~ ^feature/([a-z][a-z0-9]*(-[a-z0-9]+)*)-([1-9][0-9]*)$ ]]; then
    [[ "$name" == "${branch#feature/}" ]] || gitwo_die "Local feature workspace/branch mismatch: $name ($branch)"
    return 0
  fi
  case "$branch" in feature/*|bugfix/*|hotfix/*) ;; *) gitwo_die "Unsupported worktree branch: $branch" ;; esac
  type="$(gitwo_branch_type "$branch")"
  ticket="$(gitwo_issue_key_from_branch "$branch")"
  canonical="$(gitwo_slug "$type" "$ticket")"
  [[ "$name" == "$canonical" || "$name" =~ ^${canonical}-[1-9][0-9]*$ ]] || gitwo_die "Unexpected workspace directory: $name"
}
gitwo_slug() { printf '%s-%s' "$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')" "$1"; }
gitwo_branch() { printf '%s/%s' "$1" "$2"; }
gitwo_path() { printf '%s/%s' "$GITWO_ROOT" "$(gitwo_slug "$1" "$2")"; }
# A workspace's stable directory depends on issue key, branch type, and optional number.
# First worktree: eng-123-feature. Next: eng-123-feature-1, -2, ...
gitwo_instance_path() {
  local ticket="$1" type="$2" instance="$3" base
  gitwo_validate_type "$type"
  base="$(gitwo_workspace_name "$type" "$ticket")"
  if [[ "$instance" == 0 ]]; then
    printf '%s/%s\n' "$GITWO_ROOT" "$base"
  else
    [[ "$instance" =~ ^[1-9][0-9]*$ ]] || gitwo_die "Invalid workspace number: $instance"
    printf '%s/%s-%s\n' "$GITWO_ROOT" "$base" "$instance"
  fi
}
gitwo_counter_path() {
  printf '%s/counters/%s\n' "$GITWO_STATE" "$(gitwo_slug "$2" "$1")"
}
gitwo_next_instance() {
  local ticket="$1" type="$2" prefix dir tail counter stored='' max=-1 num branch
  prefix="$(gitwo_slug "$type" "$ticket")"
  counter="$(gitwo_counter_path "$ticket" "$type")"
  [[ ! -e "$GITWO_ROOT/$prefix" && ! -L "$GITWO_ROOT/$prefix" ]] || max=0
  if [[ -f "$counter" ]]; then
    stored="$(cat "$counter")"
    [[ "$stored" =~ ^(0|[1-9][0-9]*)$ ]] || gitwo_die "Invalid workspace counter: $counter"
    if (( stored > max )); then max="$stored"; fi
  fi
  # A deleted worktree's number is not reused when state persists.
  for dir in "$GITWO_ROOT/$prefix-"*; do
    [[ -e "$dir" || -L "$dir" ]] || continue
    tail="${dir##*/}"
    num="${tail#"$prefix-"}"
    if [[ "$num" =~ ^[1-9][0-9]*$ ]] && (( 10#$num > max )); then max="$((10#$num))"; fi
  done
  # Include existing branches even if their worktrees have been removed.
  while IFS= read -r branch; do
    if gitwo_matches_issue_branch "$branch" "$ticket" && [[ "$branch" == "$type/"* ]]; then
      (( max >= 0 )) || max=0
      # Do not mistake the digits in feature/ENG-5666 for an instance number.
      # Retained counters and actual workspace folders track numbered instances.
    fi
  done < <(git -C "$GITWO_SOURCE" for-each-ref --format='%(refname:short)' refs/heads)
  printf '%s\n' "$((max + 1))"
}
# Freeform local features use immutable, sequential N suffixes. Include old
# branches and preserved counters to avoid reusing a previous workspace name.
gitwo_next_feature_instance() {
  local name="$1" counter="$GITWO_STATE/counters/freeform-$1" max=0 stored path branch n
  gitwo_validate_feature_name "$name"
  if [[ -f "$counter" ]]; then
    stored="$(cat "$counter")"
    [[ "$stored" =~ ^[0-9]+$ ]] || gitwo_die "Invalid feature counter: $counter"
    max="$stored"
  fi
  for path in "$GITWO_ROOT/$name-"[1-9]*; do
    [[ -e "$path" || -L "$path" ]] || continue
    n="${path##*/$name-}"
    [[ "$n" =~ ^[1-9][0-9]*$ ]] || continue
    (( 10#$n > max )) && max="$((10#$n))"
  done
  while IFS= read -r branch; do
    n="${branch#feature/$name-}"
    if [[ "$branch" == feature/"$name"-* && "$n" =~ ^[1-9][0-9]*$ ]] && (( 10#$n > max )); then
      max="$((10#$n))"
    fi
  done < <(git -C "$GITWO_SOURCE" for-each-ref --format='%(refname:short)' refs/heads)
  printf '%s\n' "$((max + 1))"
}
gitwo_record_feature_instance() {
  local name="$1" instance="$2" counter="$GITWO_STATE/counters/freeform-$1"
  gitwo_validate_feature_name "$name"
  [[ "$instance" =~ ^[1-9][0-9]*$ ]] || gitwo_die 'Invalid feature instance'
  mkdir -p "$GITWO_STATE/counters"
  chmod 700 "$GITWO_STATE" "$GITWO_STATE/counters"
  (umask 077; printf '%s\n' "$instance" > "$counter")
}
gitwo_next_develop_instance() {
  local path number max=0 counter="$GITWO_STATE/counters/develop" stored branch
  if [[ -f "$counter" ]]; then
    stored="$(cat "$counter")"
    [[ "$stored" =~ ^[0-9]+$ ]] || gitwo_die 'Invalid develop counter'
    max="$stored"
  fi
  for path in "$GITWO_ROOT"/develop-[1-9]*; do
    [[ -e "$path" || -L "$path" ]] || continue
    number="${path##*/develop-}"
    if [[ "$number" =~ ^[1-9][0-9]*$ ]] && (( 10#$number > max )); then max="$((10#$number))"; fi
  done
  while IFS= read -r branch; do
    if [[ "$branch" =~ ^experiment/develop-([1-9][0-9]*)$ ]] && (( 10#${BASH_REMATCH[1]} > max )); then
      max="$((10#${BASH_REMATCH[1]}))"
    fi
  done < <(git -C "$GITWO_SOURCE" for-each-ref --format='%(refname:short)' refs/heads)
  printf '%s\n' "$((max + 1))"
}
gitwo_record_develop_instance() {
  local instance="$1" file="$GITWO_STATE/counters/develop"
  mkdir -p "$GITWO_STATE/counters"
  chmod 700 "$GITWO_STATE" "$GITWO_STATE/counters"
  (umask 077; printf '%s\n' "$instance" > "$file")
}
gitwo_record_instance() {
  local ticket="$1" type="$2" instance="$3" counter previous=-1
  counter="$(gitwo_counter_path "$ticket" "$type")"
  mkdir -p "$(dirname "$counter")"
  chmod 700 "$GITWO_STATE" "$(dirname "$counter")"
  if [[ -f "$counter" ]]; then
    previous="$(cat "$counter")"
    [[ "$previous" =~ ^(0|[1-9][0-9]*)$ ]] || gitwo_die "Invalid workspace counter: $counter"
  fi
  if (( instance > previous )); then
    (umask 077; printf '%s\n' "$instance" > "$counter")
  fi
}
gitwo_git_common() { git -C "$1" rev-parse --path-format=absolute --git-common-dir; }
gitwo_verify_target() {
  local path="$1" expected_branch="$2" actual
  [[ -d "$path" && ! -L "$path" ]] || gitwo_die "Missing worktree: $path"
  actual="$(git -C "$path" rev-parse --show-toplevel 2>/dev/null)" || gitwo_die "Not a Git worktree: $path"
  [[ "$actual" == "$path" ]] || gitwo_die "Unexpected worktree root: $actual"
  [[ "$(git -C "$path" branch --show-current)" == "$expected_branch" ]] || gitwo_die "Unexpected branch in $path (expected $expected_branch)"
  [[ "$(gitwo_git_common "$GITWO_SOURCE")" == "$(gitwo_git_common "$path")" ]] || gitwo_die "Worktree belongs to a different Git repository"
}
# Resolve an omitted workspace safely. From a worktree, use its Git root.
# From the workspace parent directory, offer an interactive choice when needed.
# Never guess a workspace when multiple candidates exist non-interactively.
gitwo_choose_workspace() {
  local path br name response index total=0 candidate
  local -a paths=() branches=()
  while IFS= read -r path; do
    [[ -n "$path" && "$path" != "$GITWO_SOURCE" ]] || continue
    [[ "${path%/*}" == "$GITWO_ROOT" && -d "$path" && ! -L "$path" ]] || continue
    name="${path##*/}"
    [[ "$name" =~ ^[a-z][a-z0-9]{1,14}-[0-9]{1,10}-(feature|bugfix|hotfix)(-[1-9][0-9]*)?$ || "$name" =~ ^develop-[1-9][0-9]*$ || "$name" =~ ^[a-z][a-z0-9]*(-[a-z0-9]+)*-[1-9][0-9]*$ ]] || continue
    br="$(git -C "$path" branch --show-current 2>/dev/null || true)"
    [[ "$br" =~ ^(feature|bugfix|hotfix)/[A-Z][A-Z0-9]{1,14}-[0-9]{1,10}(-|$) || "$br" =~ ^experiment/develop-[1-9][0-9]*$ || "$br" == feature/"$name" ]] || continue
    paths+=("$path")
    branches+=("$br")
    total=$((total + 1))
  done < <(git -C "$GITWO_SOURCE" worktree list --porcelain | sed -n 's/^worktree //p')

  (( total > 0 )) || gitwo_die "No Gitwo worktrees found. Create one with: gitwo new feature ENG-123"
  if (( total == 1 )); then
    printf '%s\n' "${paths[0]}"
    return 0
  fi
  if [[ ! -t 0 || ! -r /dev/tty ]]; then
    gitwo_die 'Multiple worktrees found. Run with a selector, e.g. gitwo up ENG-123-feature'
  fi
  printf '  Select a Gitwo workspace:\n' >&2
  for ((index=0;index<total;index++)); do
    printf '    %d) %s (%s)\n' "$((index+1))" "${paths[index]##*/}" "${branches[index]}" >&2
  done
  printf '  Choice [1-%s]: ' "$total" >&2
  IFS= read -r response </dev/tty || gitwo_die 'No workspace selected'
  [[ "$response" =~ ^[1-9][0-9]*$ ]] || gitwo_die 'Invalid workspace selection'
  (( response >= 1 && response <= total )) || gitwo_die 'Workspace selection out of range'
  printf '%s\n' "${paths[response-1]}"
}

gitwo_resolve_path() {
  local input="${1:-}" path='' matching='' n=0 p br ticket instance='' selector_type='' prefix
  if [[ -z "$input" ]]; then
    if path="$(git rev-parse --show-toplevel 2>/dev/null)"; then
      [[ "$path" != "$GITWO_SOURCE" ]] || gitwo_die 'You are in the base develop copy; pass a ticket/workspace ID'
    elif [[ "$PWD" == "$GITWO_ROOT" || "$PWD" == "$GITWO_DIR" ]]; then
      path="$(gitwo_choose_workspace)" || return 1
    else
      gitwo_die "Not inside a Gitwo worktree. From $GITWO_ROOT, pass a workspace selector or choose one interactively."
    fi
  elif [[ "$input" == /* ]]; then
    path="$input"
  else
    gitwo_need ruby
    if [[ "$input" =~ ^[a-z][a-z0-9]*(-[a-z0-9]+)*-[1-9][0-9]*$ && -d "$GITWO_ROOT/$input" &&
          "$(git -C "$GITWO_ROOT/$input" branch --show-current 2>/dev/null)" == "feature/$input" ]]; then
      path="$GITWO_ROOT/$input"
      gitwo_verify_target "$path" "feature/$input"
      gitwo_validate_workspace_identity "$path" "feature/$input"
      printf '%s\n' "$path"
      return 0
    elif [[ "$input" =~ ^develop-([1-9][0-9]*)$ ]]; then
      path="$GITWO_ROOT/$input"
      [[ -d "$path" ]] || gitwo_die "Missing develop workspace: $path"
      [[ "$(git -C "$path" branch --show-current 2>/dev/null)" == "experiment/develop-${BASH_REMATCH[1]}" ]] || gitwo_die 'Develop workspace branch does not match its directory'
      [[ "$(gitwo_git_common "$GITWO_SOURCE")" == "$(gitwo_git_common "$path")" ]] || gitwo_die 'Develop worktree belongs to a different repository'
      printf '%s\n' "$path"
      return 0
    elif [[ "$input" =~ ^([A-Za-z][A-Za-z0-9]{1,14}-[0-9]{1,10})-(feature|bugfix|hotfix)(-([1-9][0-9]*))?$ ]]; then
      ticket="${BASH_REMATCH[1]}"
      selector_type="${BASH_REMATCH[2]}"
      instance="${BASH_REMATCH[4]}"
      [[ -n "$instance" ]] || instance=0
    elif [[ "$input" =~ ^([A-Za-z][A-Za-z0-9]{1,14}-[0-9]{1,10})-([1-9][0-9]*)$ ]]; then
      ticket="${BASH_REMATCH[1]}"
      instance="${BASH_REMATCH[2]}"
    else
      ticket="$(ruby "$GITWO_DIR/provider.rb" key "$input")" || gitwo_die "Cannot parse issue selector: $input"
    fi
    ticket="$(printf '%s' "$ticket" | tr '[:lower:]' '[:upper:]')"
    gitwo_validate_ticket "$ticket"
    while IFS= read -r p; do
      [[ -n "$p" ]] || continue
      br="$(git -C "$p" branch --show-current 2>/dev/null || true)"
      if gitwo_matches_issue_branch "$br" "$ticket"; then
        if [[ -n "$selector_type" ]]; then
          [[ "$p" == "$(gitwo_instance_path "$ticket" "$selector_type" "$instance")" ]] || continue
          [[ "$br" == "$selector_type/"* ]] || continue
        elif [[ -n "$instance" ]]; then
          [[ "${p##*/}" == "$(gitwo_slug feature "$ticket")-$instance" || "${p##*/}" == "$(gitwo_slug bugfix "$ticket")-$instance" || "${p##*/}" == "$(gitwo_slug hotfix "$ticket")-$instance" ]] || continue
        fi
        matching="$p"; n=$((n + 1))
      fi
    done < <(git -C "$GITWO_SOURCE" worktree list --porcelain | sed -n 's/^worktree //p')
    [[ "$n" -gt 0 ]] || gitwo_die "No worktree found for $input"
    if [[ "$n" -gt 1 ]]; then
      gitwo_warn "Multiple worktrees for $ticket. Select a specific workspace:"
      git -C "$GITWO_SOURCE" worktree list --porcelain | sed -n 's/^worktree //p' | while IFS= read -r p; do
        br="$(git -C "$p" branch --show-current 2>/dev/null || true)"
        if gitwo_matches_issue_branch "$br" "$ticket"; then printf '  %s (%s)\n' "$(basename "$p")" "$br" >&2; fi
      done
      gitwo_die "Ambiguous issue $ticket. Use e.g. gitwo checkout ${ticket}-feature-1"
    fi
    path="$matching"
  fi
  [[ "$(gitwo_git_common "$GITWO_SOURCE")" == "$(gitwo_git_common "$path")" ]] || gitwo_die "Not a worktree of $GITWO_SOURCE"
  [[ "$path" != "$GITWO_SOURCE" ]] || gitwo_die 'Refusing to manage the base develop copy'
  printf '%s\n' "$path"
}

gitwo_expected_db_name() {
  local db_slug
  db_slug="$(basename "$1" | tr '[:lower:]-' '[:lower:]_')"
  local db="${GITWO_DB_PREFIX}_${db_slug}_${2}"
  [[ ${#db} -le 63 && "$db" =~ ^[a-z][a-z0-9_]+_(development|test)$ ]] || gitwo_die "Unsafe or too-long PostgreSQL DB name: $db"
  printf '%s\n' "$db"
}
gitwo_state_path() { printf '%s/%s.env' "$GITWO_STATE" "$(basename "$1")"; }
gitwo_load_state() {
  local file
  file="$(gitwo_state_path "$1")"
  [[ -f "$file" ]] || gitwo_die "Workspace state not found: $file (run setup.sh)"
  # State is data, not shell code. Accept only the five generated keys and
  # literal paths/identifiers, including backslash-escaped spaces from printf %q.
  # Never source metadata: it may be damaged or replaced by a local process.
  [[ ! -L "$file" ]] || gitwo_die "Unsafe workspace state symlink: $file"
  local key value count=0 seen='|' line
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^(GITWO_PATH|GITWO_TYPE|GITWO_TICKET|GITWO_DB_DEV|GITWO_DB_TEST)= ]] || gitwo_die "Unexpected workspace state entry: $file"
    key="${line%%=*}"
    value="${line#*=}"
    [[ "$value" =~ ^([A-Za-z0-9_./+-]|\\[[:space:]])+$ ]] || gitwo_die "Unsafe workspace state value: $key"
    [[ "$seen" != *"|$key|"* ]] || gitwo_die "Duplicate workspace state key: $key"
    seen="${seen}${key}|"; count=$((count + 1))
    value="${value//\\ / }"
    case "$key" in
      GITWO_PATH) GITWO_PATH="$value" ;;
      GITWO_TYPE) GITWO_TYPE="$value" ;;
      GITWO_TICKET) GITWO_TICKET="$value" ;;
      GITWO_DB_DEV) GITWO_DB_DEV="$value" ;;
      GITWO_DB_TEST) GITWO_DB_TEST="$value" ;;
    esac
  done < "$file"
  [[ "$count" -eq 5 ]] || gitwo_die "Incomplete workspace state: $file"
  [[ "$GITWO_PATH" == "$1" ]] || gitwo_die 'Workspace state/path mismatch'
  [[ "$GITWO_DB_DEV" == "$(gitwo_expected_db_name "$1" development)" && "$GITWO_DB_TEST" == "$(gitwo_expected_db_name "$1" test)" ]] || gitwo_die 'Unexpected DB names in workspace state'
}
gitwo_write_state() {
  local path="$1" type="$2" ticket="$3" slug db_name file
  # Keep the original DB for the unnumbered worktree and isolate numbered ones.
  slug="$(basename "$path")"
  if [[ "$type" == develop ]]; then
    [[ "$slug" == "$(gitwo_workspace_name "$type" "$ticket")" ]] || gitwo_die "Unexpected develop workspace directory: $slug"
  elif [[ "$type" == feature && "$ticket" =~ ^[a-z][a-z0-9]*(-[a-z0-9]+)*-[1-9][0-9]*$ &&
            "$slug" == "$ticket" ]]; then
    : # Freeform features use their normalized name plus instance as identity.
  elif [[ "$slug" != "$(gitwo_slug "$type" "$ticket")" && ! "$slug" =~ ^$(gitwo_slug "$type" "$ticket")-[1-9][0-9]*$ ]]; then
    gitwo_die "Unexpected workspace directory for $ticket: $slug"
  fi
  db_name="$(printf '%s' "$slug" | tr '[:lower:]-' '[:lower:]_')"
  mkdir -p "$GITWO_STATE"
  chmod 700 "$GITWO_STATE"
  file="$(gitwo_state_path "$path")"
  if [[ ! -e "$file" ]]; then
    (
      umask 077
      printf 'GITWO_PATH=%q\n' "$path"
      printf 'GITWO_TYPE=%q\n' "$type"
      printf 'GITWO_TICKET=%q\n' "$ticket"
      printf 'GITWO_DB_DEV=%q\n' "$(gitwo_expected_db_name "$path" development)"
      printf 'GITWO_DB_TEST=%q\n' "$(gitwo_expected_db_name "$path" test)"
    ) > "$file"
  fi
  gitwo_load_state "$path"
}
gitwo_db_settings() {
  export GITWO_DB_HOST="${GITWO_DB_HOST:-localhost}" GITWO_DB_PORT="${GITWO_DB_PORT:-5432}"
  export GITWO_DB_USER="${GITWO_DB_USER:-${USER:-postgres}}"
  if [[ "$GITWO_SERVICES_BACKEND" == compose ]]; then
    [[ -n "${GITWO_PATH:-}" ]] || gitwo_die "Compose backend requires selected workspace identity"
    gitwo_compose_apply "$GITWO_PATH"
  fi
  case "$GITWO_DB_HOST" in localhost|127.0.0.1) ;; *) gitwo_die "Refusing non-local PostgreSQL host: $GITWO_DB_HOST" ;; esac
  [[ "$GITWO_DB_PORT" =~ ^[0-9]{2,5}$ ]] || gitwo_die 'Invalid local DB port'
}
gitwo_db_url() { printf 'postgresql://%s:%s/%s' "$GITWO_DB_HOST" "$GITWO_DB_PORT" "$1"; }
# APP_HOST is required by the existing legacy application Devise mailer during db:seed.
# Keep the source repository unchanged and allow an explicit per-workspace override.
gitwo_app_host() {
  printf '%s\n' "${GITWO_APP_HOST:-${APP_HOST:-localhost:3000}}"
}
gitwo_pg() {
  PGHOST="$GITWO_DB_HOST" PGPORT="$GITWO_DB_PORT" PGUSER="$GITWO_DB_USER" PGCONNECT_TIMEOUT=5 "$@"
}
gitwo_rails() {
  local env_name="$1" db="$GITWO_DB_DEV"
  shift
  [[ "$env_name" == development || "$env_name" == test ]] || gitwo_die 'Only development/test environment is supported'
  [[ "$env_name" == test ]] && db="$GITWO_DB_TEST"
  APP_HOST="$(gitwo_app_host)" RAILS_ENV="$env_name" RACK_ENV="$env_name" DATABASE_URL="$(gitwo_db_url "$db")" DB_HOST="$GITWO_DB_HOST" DB_PORT="$GITWO_DB_PORT" DB_USERNAME="$GITWO_DB_USER" GITWO_DB_DEV="$GITWO_DB_DEV" GITWO_DB_TEST="$GITWO_DB_TEST" \
    PGHOST="$GITWO_DB_HOST" PGPORT="$GITWO_DB_PORT" PGUSER="$GITWO_DB_USER" mise exec "ruby@${GITWO_RUBY_VERSION}" -- "$@"
}
gitwo_ruby_version() {
  [[ -f "$1/.ruby-version" ]] || gitwo_die "Missing .ruby-version in $1"
  GITWO_RUBY_VERSION="$(tr -d '[:space:]' < "$1/.ruby-version")"
  [[ "$GITWO_RUBY_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || gitwo_die "Unexpected Ruby version: $GITWO_RUBY_VERSION"
}

# Workspace service backend is a separate layer from Rails and worktree state.
source "$GITWO_DIR/_services.sh"
