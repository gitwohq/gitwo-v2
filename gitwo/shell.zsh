# Local Gitwo shell integration for zsh. Source it from ~/.zshrc.
# The real scripts run in child processes; only this function can cd the current shell.
# Always resolve this sourced installation, avoiding a stale previous version.
if [[ -n "${ZSH_VERSION:-}" ]]; then
  GITWO_LOCAL_DIR="${${(%):-%x}:A:h}"
else
  GITWO_LOCAL_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
fi

# Some applications need APP_HOST for locally generated URLs.
# Export it only when explicitly configured; runtime setup handles its own host.
_gitwo_activate_app_host() {
  # Never inject a generic host into arbitrary applications.
  [[ -n "${GITWO_APP_HOST:-}" ]] || return 0
  export APP_HOST="$GITWO_APP_HOST"
  GITWO_ACTIVE_APP_HOST="$APP_HOST"
}

_gitwo_deactivate_app_host() {
  if [[ -n "${GITWO_ACTIVE_APP_HOST:-}" && "${APP_HOST:-}" == "$GITWO_ACTIVE_APP_HOST" ]]; then
    unset APP_HOST
  fi
  unset GITWO_ACTIVE_APP_HOST
}

gitwo() {
  local action="${1:-}" target option required_script=""
  [[ $# -gt 0 ]] && shift
  # Help must never start Rails, prompt for Jira, or modify a workspace.
  if [[ -z "$action" || "$action" == -h || "$action" == --help ]]; then
    "$GITWO_LOCAL_DIR/help.sh"
    return $?
  fi
  if [[ "$action" == help ]]; then
    "$GITWO_LOCAL_DIR/help.sh" "$@"
    return $?
  fi
  for option in "$@"; do
    if [[ "$option" == --help || "$option" == -h ]]; then
      "$GITWO_LOCAL_DIR/help.sh" "$action"
      return $?
    fi
  done
  case "$action" in
    new) required_script=new.sh ;;
    checkout|co|switch) required_script=checkout.sh ;;
    jira-init) required_script=jira-init.sh ;;
    jira-test) required_script=jira-test.sh ;;
    list|ls) required_script=list.sh ;;
    status) required_script=status.sh ;;
    up|run) required_script=run.sh ;;
    down|logs|remove|open|env|dump|clean|repair) required_script="$action.sh" ;;
    redis) required_script=redis.sh ;;
    services) required_script=services.sh ;;
    init) required_script=onboard.rb ;;
    detect) required_script=onboard.rb ;;
    workspace) required_script=workspace-env.sh ;;
    setup) required_script=setup.sh ;;
    version|--version) required_script=VERSION ;;
    doctor) required_script=doctor.sh ;;
    config) required_script=config.sh ;;
  esac
  if [[ -n "$required_script" && ! -s "$GITWO_LOCAL_DIR/$required_script" ]]; then
    print -u2 -- "gitwo: missing or empty $GITWO_LOCAL_DIR/$required_script (incomplete installation; restore the script)"
    return 127
  fi
  case "$action" in
    new)
      # Help and preview are informational: do not treat stdout as a path.
      for option in "$@"; do
        case "$option" in
          -h|--help|--preview)
            "$GITWO_LOCAL_DIR/new.sh" "$@"
            return $? ;;
        esac
      done
      target="$("$GITWO_LOCAL_DIR/new.sh" "$@")" || return $?
      [[ -d "$target" ]] || { print -u2 -- "gitwo: invalid worktree path: $target"; return 1; }
      builtin cd -- "$target" || return $?
      _gitwo_deactivate_app_host
      if [[ -f .envrc ]]; then
        print -u2 -- 'gitwo: workspace environment uses direnv. Review .envrc and run direnv allow . once.'
      else
        print -u2 -- 'gitwo: workspace environment is not activated. Run gitwo workspace env init after Rails setup.'
      fi
      print -P -- "%F{green}gitwo%f  →  ${PWD}"
      ;;
    checkout|co|switch)
      [[ $# -le 1 ]] || { print -u2 -- 'Usage: gitwo checkout [ENG-123-feature-1]'; return 2; }
      target="$("$GITWO_LOCAL_DIR/checkout.sh" "${1:-}")" || return $?
      builtin cd -- "$target" || return $?
      _gitwo_deactivate_app_host
      if [[ -f .envrc ]]; then
        print -u2 -- 'gitwo: workspace environment uses direnv. Review .envrc and run direnv allow . once.'
      else
        print -u2 -- 'gitwo: workspace environment is not activated. Run gitwo workspace env init after Rails setup.'
      fi
      print -P -- "%F{green}gitwo%f  →  ${PWD}"
      ;;
    base)
      target="$("$GITWO_LOCAL_DIR/base.sh")" || return $?
      builtin cd -- "$target" || return $?
      _gitwo_deactivate_app_host
      ;;
    doctor)
      "$GITWO_LOCAL_DIR/doctor.sh" "$@"
      ;;
    config)
      "$GITWO_LOCAL_DIR/config.sh" "$@"
      ;;
    jira-init)
      "$GITWO_LOCAL_DIR/jira-init.sh" "$@"
      ;;
    jira-test)
      "$GITWO_LOCAL_DIR/jira-test.sh" "$@"
      ;;
    list|ls)
      "$GITWO_LOCAL_DIR/list.sh" "$@"
      ;;
    status)
      "$GITWO_LOCAL_DIR/status.sh" "$@"
      ;;
    up)
      if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then
        print -- 'Usage: gitwo up [WORKSPACE]'
        print -- 'Prepare (with safe adoption confirmation) and launch Rails + Redis via Portless.'
        return 0
      fi
      "$GITWO_LOCAL_DIR/run.sh" "$@" server
      ;;
    down|logs|open|env|dump|clean|repair)
      "$GITWO_LOCAL_DIR/$action.sh" "$@"
      ;;
    remove)
      if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then
        "$GITWO_LOCAL_DIR/remove.sh" --help
        return $?
      fi
      local workspace_selector="" resolved_workspace="" dryrun=no
      local -a remove_options=()
      for option in "$@"; do
        case "$option" in
          --dry-run) dryrun=yes; remove_options+=("$option") ;;
          --delete-ignored|--delete-db) remove_options+=("$option") ;;
          -*) print -u2 -- "gitwo: unknown remove option: $option"; return 2 ;;
          *)
            [[ -z "$workspace_selector" ]] || { print -u2 -- 'Usage: gitwo remove [WORKSPACE] [--dry-run] [--delete-ignored] [--delete-db]'; return 2; }
            workspace_selector="$option"
            ;;
        esac
      done
      resolved_workspace="$("$GITWO_LOCAL_DIR/checkout.sh" "$workspace_selector")" || return $?
      # Do not leave the interactive shell inside a directory about to be deleted.
      if [[ "$dryrun" != yes && ( "$PWD" == "$resolved_workspace" || "$PWD" == "$resolved_workspace/"* ) ]]; then
        local source_root="$(git -C "$resolved_workspace" worktree list --porcelain | sed -n 's/^worktree //p' | head -1)"
        builtin cd -- "$source_root" || return $?
        _gitwo_deactivate_app_host
      fi
      "$GITWO_LOCAL_DIR/remove.sh" "$resolved_workspace" "${remove_options[@]}"
      ;;
    redis)
      "$GITWO_LOCAL_DIR/redis.sh" "$@"
      ;;
    services)
      "$GITWO_LOCAL_DIR/services.sh" "$@"
      ;;
    init)
      # Preserve the v4.19 DB adoption command for existing local workspaces.
      local is_legacy=no
      for option in "$@"; do [[ "$option" == --adopt-db ]] && is_legacy=yes; done
      if [[ "$is_legacy" == yes || ( $# -gt 0 && "$1" != -* ) ]]; then
        "$GITWO_LOCAL_DIR/init.sh" "$@"
      else
        ruby "$GITWO_LOCAL_DIR/onboard.rb" init "$@"
      fi
      ;;
    detect)
      ruby "$GITWO_LOCAL_DIR/onboard.rb" detect "$@"
      ;;
    workspace)
      local workspace_action="${1:-}"
      [[ $# -eq 0 ]] || shift
      case "$workspace_action" in
        create) gitwo new "$@" ;;
        enter|checkout) gitwo checkout "$@" ;;
        env) "$GITWO_LOCAL_DIR/workspace-env.sh" "$@" ;;
        proxy) "$GITWO_LOCAL_DIR/proxy.sh" "$@" ;;
        adopt) "$GITWO_LOCAL_DIR/init.sh" "$@" ;;
        *) print -u2 -- 'Usage: gitwo workspace <create|enter|env|proxy|adopt> ...'; return 2 ;;
      esac
      ;;
    setup|run)
      "$GITWO_LOCAL_DIR/$action.sh" "$@"
      ;;
    --version|version)
      if [[ -s "$GITWO_LOCAL_DIR/VERSION" ]]; then
        print -- "gitwo $(< "$GITWO_LOCAL_DIR/VERSION")"
      else
        print -u2 -- 'gitwo: missing VERSION file'
        return 1
      fi
      ;;
    *)
      print -u2 -- "gitwo: unknown command: $action"
      return 2
      ;;
  esac
}

# Short aliases are opt-in to avoid overriding existing shell commands.
if [[ "${GITWO_ENABLE_SHORTCUTS:-0}" == 1 ]]; then
  b()    { gitwo base "$@"; }
  bnew() { gitwo new "$@"; }
  bco()  { gitwo checkout "$@"; }
fi
