#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/_common.sh"
source "$GITWO_DIR/provider-env.sh"
usage() { cat >&2 <<'USAGE'
Usage: new.sh feature [NAME|ENG-123|JIRA_URL] [options]
       new.sh <hotfix|bugfix> <ISSUE> [options]
       new.sh develop [options]     # Sequential local experiments without Jira

Examples (from ANY directory):
  gitwo new feature "Improve search"    # Full Rails setup, no issue tracker or remote
  gitwo new feature ENG-123 --title "Fix API URL in HTTP client"
  gitwo new hotfix https://company.atlassian.net/browse/ENG-125 --no-setup
  gitwo new feature ENG-123 --instance 1 --resume

Options:
  --title "TITLE"  Set issue title manually (no network call).
  --offline        Create a ticket-only branch without a provider API call.
  --no-setup       Explicitly skip Rails dependencies and isolated databases.
                   By default, Gitwo prepares the full Rails workspace.
  --db=schema      Bootstrap database from Rails schema (default).
  --db=baseline    Restore locally prepared snapshot into a NEW database.
  --test           Run known RSpec smoke tests during setup.
  --seed           Explicitly request seeds (default for new schema DB).
  --no-seed        Skip seeds when creating a NEW schema DB.
  --dump=PATH      Restore a pg_dump archive from the configured dumps directory instead of seeds.
                   PATH may be a file or a dated directory with one archive.
  --rebuild-db     Explicit reset for a managed partial DB. Requires --seed and confirmation.
  --instance N     Use an explicit workspace number (ticket: 0,1,...; develop: 1,2,...). Auto-increment otherwise.
  --resume         Resume existing worktree without modifying its Git branch.
  --preview        Display resolved branch, base and path without creating it.
  --verbose        Stream dependency/build output instead of concise steps.

Notes:
  Feature names are normalized to short slugs, with sequential local names.
  Issue title lookup applies only when an issue identifier is provided.
  Only a worktree path is written to stdout on successful creation.
USAGE
}
if [[ "${1:-}" == -h || "${1:-}" == --help ]]; then usage; exit 0; fi
if [[ $# -lt 1 ]]; then
  gitwo_warn 'Expected branch type or develop'
  usage
  exit 2
fi
type="$1"; shift
gitwo_validate_type "$type"
issue=''
if [[ "$type" != develop ]]; then
  if [[ $# -ge 1 && "$1" != --* ]]; then
    issue="$1"; shift
  elif [[ "$type" == feature && -t 0 ]]; then
    printf 'Feature name (no Jira or GitHub issue required): ' >&2
    IFS= read -r issue || gitwo_die 'Feature naming cancelled'
    [[ -n "$issue" ]] || gitwo_die 'Feature name cannot be blank'
  else
    gitwo_die 'Enter a feature name or issue key (interactive terminal can prompt for a name)'
  fi
fi
setup=yes; resume=no; db=schema; db_explicit=no; tests=no; seed=auto; seed_yes_seen=no; seed_no_seen=no; dump_ref=''; rebuild_db=no; preview=no; title=''; offline=no; instance=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-setup) setup=no ;;
    --resume) resume=yes ;;
    --instance)
      [[ $# -ge 2 ]] || gitwo_die 'Missing value for --instance'
      instance="$2"; shift ;;
    --instance=*) instance="${1#--instance=}" ;;
    --test) tests=yes ;;
    --seed) seed=yes; seed_yes_seen=yes ;;
    --no-seed) seed=no; seed_no_seen=yes ;;
    --dump=*) dump_ref="${1#--dump=}"; [[ -n "$dump_ref" ]] || gitwo_die 'Missing path for --dump' ;;
    --dump)
      [[ $# -ge 2 ]] || gitwo_die 'Missing path for --dump'
      dump_ref="$2"; shift ;;
    --rebuild-db) rebuild_db=yes ;;
    --db=schema) db=schema; db_explicit=yes ;;
    --db=baseline) db=baseline; db_explicit=yes ;;
    --offline) offline=yes ;;
    --preview) preview=yes ;;
    --verbose) GITWO_VERBOSE=1; export GITWO_VERBOSE ;;
    --title)
      [[ $# -ge 2 ]] || gitwo_die 'Missing value for --title'
      title="$2"; shift ;;
    --title=*) title="${1#--title=}" ;;
    -h|--help) usage; exit 0 ;;
    *) gitwo_die "Unknown option: $1" ;;
  esac
  shift
done
# Feature descriptions without issue identifiers are first-class local work.
# Normalize with the existing Unicode/Cyrillic-aware title slugger, then
# impose a short safe name for the isolated PostgreSQL database identifier.
freeform=no; feature_name=''
github_issue=no
if [[ "${GITWO_ISSUE_PROVIDER:-none}" == github && "$issue" =~ ^(#|GH-)?[1-9][0-9]*$ ]]; then
  github_issue=yes
fi
if [[ "$type" == feature && ! "$issue" =~ ^[A-Za-z][A-Za-z0-9]{1,14}-[0-9]{1,10}$ &&
      "$issue" != https://* && "$github_issue" == no ]]; then
  feature_name="$(ruby "$GITWO_DIR/issue.rb" slug "$issue" | tr '[:upper:]' '[:lower:]')" ||
    gitwo_die 'Feature name contains no usable characters'
  if (( ${#feature_name} > 24 )); then
    # Keep names meaningful but always fit PostgreSQL's 63-character identifiers.
    # The suffix distinguishes long names sharing the same visible prefix.
    digest="$(printf '%s' "$feature_name" | ruby -rdigest -e 'print Digest::SHA256.hexdigest(STDIN.read)[0, 6]')"
    stem="${feature_name:0:17}"
    stem="${stem%-}"
    feature_name="$stem-$digest"
  fi
  gitwo_validate_feature_name "$feature_name"
  [[ -z "$title" && "$offline" == no ]] ||
    gitwo_die '--title and --offline apply to issue keys, not freeform feature names'
  freeform=yes
fi
# No issue provider means no external lookup.
if [[ "$type" != develop && "$freeform" == no ]]; then
  case "${GITWO_ISSUE_PROVIDER:-jira}" in
    none) [[ "$resume" == yes || "$offline" == yes || -n "$title" ]] || offline=yes ;;

  esac
fi
[[ "$seed_yes_seen" == no || "$seed_no_seen" == no ]] || gitwo_die 'Cannot combine --seed and --no-seed'
[[ -z "$instance" || "$instance" =~ ^[1-9][0-9]*$ ]] || gitwo_die 'Workspace instance must be a positive integer'
[[ "$offline" == no || -z "$title" ]] || gitwo_die 'Cannot combine --title and --offline'
[[ "$type" != develop || ( "$offline" == no && -z "$title" ) ]] || gitwo_die 'Local develop workspaces do not use Jira options' 
[[ "$resume" == no || "$preview" == no ]] || gitwo_die 'Cannot combine --resume and --preview'
[[ "$type" != develop || "$resume" == no || -n "$instance" ]] || gitwo_die 'Develop --resume requires --instance N' 
[[ "$resume" == no || "$offline" == no && -z "$title" ]] || gitwo_die '--resume does not accept --title or --offline'
[[ "$setup" == yes || "$tests" == no && "$seed" == auto && "$rebuild_db" == no && -z "$dump_ref" ]] || gitwo_die '--test/--seed/--no-seed/--dump/--rebuild-db require setup'
[[ "$rebuild_db" == no || "$resume" == yes && "$seed" == yes ]] || gitwo_die '--rebuild-db requires --resume --seed; use setup.sh for an existing workspace'
if [[ -n "$dump_ref" ]]; then
  [[ "$db_explicit" == no ]] || gitwo_die 'Cannot combine --dump and --db'
  [[ "$seed" == auto ]] || gitwo_die 'Cannot combine --dump with --seed/--no-seed'
  [[ "$rebuild_db" == no ]] || gitwo_die 'Cannot rebuild an existing DB with --dump'
  [[ "$setup" == yes ]] || gitwo_die '--dump requires setup'
  db=dump
fi
# Apply the project default only after parsing the explicit data and no-setup flags.
if [[ "$seed" == auto && "$db" == schema && "${GITWO_BOOTSTRAP:-seeds}" == schema ]]; then seed=no; fi
export GITWO_ISSUE_PROVIDER GITWO_ISSUE_URL GITWO_SOURCE
gitwo_need git; gitwo_need ruby
gitwo_check_source
# A shared, atomic mkdir lock prevents duplicate suffixes across simultaneous terminals.
# No lock is created for read-only preview or resume.
create_lock=''
if [[ "$resume" == no && "$preview" == no ]]; then
  mkdir -p "$GITWO_GLOBAL_STATE_ROOT" "$GITWO_STATE"
  chmod 700 "$GITWO_GLOBAL_STATE_ROOT" "$GITWO_STATE"
  create_lock="$GITWO_STATE/.create-lock"
  got_lock=no
  for ((attempt=0;attempt<200;attempt++)); do
    if mkdir "$create_lock" 2>/dev/null; then got_lock=yes; break; fi
    sleep 0.1
  done
  [[ "$got_lock" == yes ]] || gitwo_die "Gitwo creation lock is busy: $create_lock (inspect with gitwo clean)"
  trap 'rmdir "$create_lock" 2>/dev/null || true' EXIT
fi
if [[ "$type" == develop ]]; then
  [[ -z "$instance" || "$instance" =~ ^[1-9][0-9]*$ ]] || gitwo_die 'Develop instances start at 1'
  [[ -n "$instance" ]] || instance="$(gitwo_next_develop_instance)"
  ticket="DEVELOP-$instance"
  target="$GITWO_ROOT/develop-$instance"
  branch="experiment/develop-$instance"
  if [[ "$resume" == yes ]]; then
    target="$(gitwo_resolve_path "develop-$instance")"
    branch="$(git -C "$target" branch --show-current)"
    gitwo_verify_target "$target" "$branch"
  fi
elif [[ "$freeform" == yes ]]; then
  if [[ "$resume" == yes ]]; then
    [[ -n "$instance" ]] || gitwo_die 'Freeform feature --resume requires --instance=N'
  else
    [[ -n "$instance" ]] || instance="$(gitwo_next_feature_instance "$feature_name")"
  fi
  ticket="$feature_name-$instance"
  target="$GITWO_ROOT/$ticket"
  branch="feature/$ticket"
  if [[ "$resume" == yes ]]; then
    target="$(gitwo_resolve_path "$ticket")"
    gitwo_verify_target "$target" "$branch"
  fi
else
  # Jira/GitHub/Linear keys retain their existing branch contract.
  ticket="$(ruby "$GITWO_DIR/provider.rb" key "$issue")" || exit 2
  gitwo_validate_ticket "$ticket"
fi
if [[ "$type" != develop && "$freeform" == no && "$resume" == yes ]]; then
  if [[ -n "$instance" ]]; then
    if [[ "$instance" == 0 ]]; then
      target="$(gitwo_resolve_path "${ticket}-${type}")"
    else
      target="$(gitwo_resolve_path "${ticket}-${type}-${instance}")"
    fi
  else
    target="$(gitwo_resolve_path "$ticket")"
  fi
  branch="$(git -C "$target" branch --show-current)"
  [[ "$branch" == "$type/"* ]] && gitwo_matches_issue_branch "$branch" "$ticket" || gitwo_die "Worktree is not $type for $ticket: $branch"
  gitwo_verify_target "$target" "$branch"
  gitwo_log "Resuming $branch without fetching or changing its Git state"
elif [[ "$type" != develop && "$freeform" == no ]]; then
  [[ -n "$instance" ]] || instance="$(gitwo_next_instance "$ticket" "$type")"
  target="$(gitwo_instance_path "$ticket" "$type" "$instance")"
  resolution_args=(resolve "$issue")
  if [[ -n "$title" ]]; then
    resolution_args+=(--title "$title")
  elif [[ "$offline" == yes ]]; then
    resolution_args+=(--offline)
  fi
  resolution="$(gitwo_provider_resolve "${resolution_args[@]}")" || exit 2
  IFS='|' read -r resolved_ticket slug <<< "$resolution"
  [[ "$resolved_ticket" == "$ticket" ]] || gitwo_die 'Unexpected Jira issue key changed during resolution'
  branch="$(gitwo_branch "$type" "$ticket")"
  [[ -z "$slug" ]] || branch="$branch-$slug"
  [[ "$instance" == 0 ]] || branch="$branch-$instance"
  git check-ref-format --branch "$branch" >/dev/null || gitwo_die "Invalid Git branch name: $branch"
fi
if [[ -n "$dump_ref" ]]; then
  # Fail before creating a Git branch if the archive path is invalid.
  source "$GITWO_DIR/_dumps.sh"
  dump_ref="$(gitwo_dump_resolve "$dump_ref")"
fi
if [[ "$freeform" == yes ]]; then
  # Local personal features do not require an origin remote or API access.
  base_kind=local
  base="$GITWO_BASE_BRANCH"
  git -C "$GITWO_SOURCE" show-ref --verify --quiet "refs/heads/$base" ||
    gitwo_die "Local base branch missing: $base"
else
  case "$type" in
    hotfix) base="${GITWO_HOTFIX_BASE}" ;;
    *) base="${GITWO_FEATURE_BASE}" ;;
  esac
  if [[ "$base" == origin/* ]]; then
  base_kind=remote
else
  [[ "$base" =~ ^[A-Za-z][A-Za-z0-9._-]*$ ]] || gitwo_die "Unsafe local base ref: $base"
  base_kind=local
  git -C "$GITWO_SOURCE" show-ref --verify --quiet "refs/heads/$base" ||
    gitwo_die "Local base branch missing: $base"
fi
fi

if [[ "$preview" == yes ]]; then
  printf 'Issue:    %s\n' "$ticket"
  printf 'Branch:   %s\n' "$branch"
  printf 'Base:     %s\n' "$base"
  printf 'Worktree: %s\n' "$target"
  if [[ -n "$dump_ref" ]]; then printf 'Data:     dump (%s)\n' "$dump_ref"; elif [[ "$db" == baseline ]]; then printf 'Data:     legacy baseline\n'; elif [[ "$seed" == no ]]; then printf 'Data:     schema only\n'; else printf 'Data:     schema + seeds\n'; fi
  exit 0
fi

new_error() {
  local status="$?"
  if [[ -d "$target" ]]; then
    if [[ "$type" == develop ]]; then
      gitwo_warn "Workspace preserved after failure. Retry with: gitwo new develop --resume --instance $instance"
    else
      # Preserve the exact issue/name and numbered instance in recovery hints.
      printf -v quoted_issue '%q' "$issue"
      retry_command="$GITWO_DIR/new.sh $type $quoted_issue"
      [[ -z "$instance" || "$instance" == 0 ]] || retry_command+=" --instance $instance"
      gitwo_warn "Workspace preserved after failure. Retry with: $retry_command --resume"
    fi
  fi
  return "$status"
}
trap new_error ERR
gitwo_ui_start "${type} workspace" "$ticket"
if [[ "$freeform" == yes ]]; then
  gitwo_ui_meta "Feature" "$feature_name"
else
  gitwo_ui_meta "Issue" "$ticket"
fi
gitwo_ui_meta "Instance" "${instance:-0}"
gitwo_ui_meta "Branch" "$branch"
gitwo_ui_meta "Base" "$base"
gitwo_ui_meta "Directory" "$target"
if [[ -n "$dump_ref" ]]; then gitwo_ui_meta "Data" "Restore: $dump_ref"; elif [[ "$db" == baseline ]]; then gitwo_ui_meta "Data" 'Legacy baseline snapshot'; elif [[ "$seed" == no ]]; then gitwo_ui_meta "Data" 'Schema only'; else gitwo_ui_meta "Data" 'Schema + default seeds'; fi
if [[ "$resume" == no ]]; then
  [[ ! -e "$target" && ! -L "$target" ]] || gitwo_die "Target already exists: $target. Use --resume"
  if git -C "$GITWO_SOURCE" show-ref --verify --quiet "refs/heads/$branch"; then
    gitwo_die "Local branch already exists: $branch (refusing reset)"
  fi
  gitwo_ui_section '01  Git / source'
  if [[ "$base_kind" == local ]]; then
    gitwo_log "Local feature base: $base (no remote fetch required)"
  else
    gitwo_ui_run 'Fetch origin (keep local develop unchanged)' git -C "$GITWO_SOURCE" fetch --prune origin
    git -C "$GITWO_SOURCE" show-ref --verify --quiet "refs/remotes/$base" || gitwo_die "Missing remote ref $base"
    if git -C "$GITWO_SOURCE" show-ref --verify --quiet "refs/remotes/origin/$branch"; then
      gitwo_die "Remote branch already exists: origin/$branch. Refusing duplicate"
    fi
  fi
  mkdir -p "$GITWO_ROOT"
  gitwo_ui_run "Create worktree from $base" git -C "$GITWO_SOURCE" worktree add --no-track -b "$branch" "$target" "$base"
  if [[ "$type" == develop ]]; then
    gitwo_record_develop_instance "$instance"
  elif [[ "$freeform" == yes ]]; then
    gitwo_record_feature_instance "$feature_name" "$instance"
  else
    gitwo_record_instance "$ticket" "$type" "$instance"
  fi
  created_marker="$GITWO_STATE/$(basename "$target").created-at"
  [[ ! -e "$created_marker" && ! -L "$created_marker" ]] || gitwo_die "Existing creation marker for new workspace: $created_marker"
  (umask 077; date -u '+%Y-%m-%dT%H:%M:%SZ' > "$created_marker")
fi
if [[ "$setup" == yes ]]; then
  args=("$target")
  [[ "$db" == dump ]] || args+=("--db=$db")
  [[ "$tests" == yes ]] && args+=(--test)
  [[ "$seed" == yes ]] && args+=(--seed)
  [[ "$seed" == no ]] && args+=(--no-seed)
  [[ -n "$dump_ref" ]] && args+=("--dump=$dump_ref")
  [[ "$rebuild_db" == yes ]] && args+=(--rebuild-db)
  gitwo_ui_section "02  Rails / setup"
  "$GITWO_DIR/setup.sh" "${args[@]}" >&2
  # Existing .envrc is the application's contract, not ours to replace.
  # Rails remains isolated through gitwo run even without native direnv setup.
  if [[ -e "$target/.envrc" || -L "$target/.envrc" ]]; then
    gitwo_log 'Existing application .envrc preserved. No Gitwo activation file generated.'
    gitwo_log "Use: gitwo run $(basename "$target") rails <command> (isolated DB)"
    gitwo_log 'Native bin/rails isolation has not been verified by Gitwo.'
  elif [[ -e "$GITWO_SOURCE/.envrc" || -L "$GITWO_SOURCE/.envrc" ]]; then
    gitwo_warn 'Application .envrc exists in the primary checkout but was not transferable. Not generating a replacement.'
    gitwo_log "Use: gitwo run $(basename "$target") rails <command> (isolated DB)"
  elif ! "$GITWO_DIR/workspace-env.sh" init "$target" >&2; then
    gitwo_warn 'Rails workspace is ready through gitwo run, but native bin/rails isolation was not verified.'
    gitwo_log "Use: gitwo run $(basename "$target") rails <command> (isolated DB)"
    gitwo_log 'Optional native activation: gitwo workspace env integrate --dry-run'
  fi
else
  gitwo_warn 'Rails setup skipped. Run setup.sh explicitly when ready.'
fi
gitwo_ui_done "Ready: $target"
printf '%s\n' "$target"
