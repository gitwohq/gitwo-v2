#!/usr/bin/env bash
# Safe workspace process inspection. Sourced after _common.sh and _runtime.sh.
# Never trust a PID alone: processes can reuse IDs after a server stops.

gitwo_puma_pidfile() { printf '%s/tmp/pids/server.pid\n' "$1"; }

gitwo_puma_pid() {
  local file pid
  file="$(gitwo_puma_pidfile "$1")"
  [[ -e "$file" || -L "$file" ]] || return 1
  if [[ ! -f "$file" || -L "$file" ]]; then
    gitwo_warn "Unsafe Puma PID file: $file"
    return 2
  fi
  pid="$(cat "$file")"
  if [[ ! "$pid" =~ ^[1-9][0-9]*$ ]]; then
    gitwo_warn "Invalid Puma PID file: $file"
    return 2
  fi
  printf '%s\n' "$pid"
}

_gitwo_process_cwd() {
  local pid="$1" path
  if [[ -L "/proc/$pid/cwd" ]]; then
    path="$(readlink -f "/proc/$pid/cwd" 2>/dev/null || true)"
    [[ -n "$path" ]] || return 1
    printf '%s\n' "$path"
  elif command -v lsof >/dev/null 2>&1; then
    # macOS: inspect the running process rather than assuming a PID file is reliable.
    lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -n 1
  else
    return 1
  fi
}

_gitwo_process_stopped() {
  local pid="$1" status
  ! kill -0 "$pid" 2>/dev/null && return 0
  status="$(ps -p "$pid" -o stat= 2>/dev/null || true)"
  [[ "$status" == Z* ]]
}

gitwo_puma_owned() {
  local target="$1" pid="$2" command cwd
  command="$(ps -p "$pid" -o command= 2>/dev/null || true)"
  [[ "$command" == *puma* || "$command" == *rails\ server* ]] || return 1
  cwd="$(_gitwo_process_cwd "$pid")" || return 1
  [[ "$cwd" == "$target" ]]
}

gitwo_puma_status() {
  local target="$1" pid status
  if pid="$(gitwo_puma_pid "$target")"; then
    :
  else
    status=$?
    [[ "$status" == 1 ]] || gitwo_die "Invalid Puma PID metadata for $target"
    printf 'stopped\n'
    return 0
  fi
  if _gitwo_process_stopped "$pid"; then
    printf 'stopped (stale pidfile or exited process)\n'
  elif gitwo_puma_owned "$target" "$pid"; then
    printf 'running (PID %s)\n' "$pid"
  else
    printf 'foreign/unknown (PID %s)\n' "$pid"
  fi
}

gitwo_puma_stop() {
  local target="$1" pid attempt status
  if pid="$(gitwo_puma_pid "$target")"; then
    :
  else
    status=$?
    [[ "$status" == 1 ]] || gitwo_die "Invalid Puma PID metadata for $target"
    gitwo_log 'Puma: no PID file; nothing to stop'
    return 0
  fi
  if _gitwo_process_stopped "$pid"; then
    gitwo_log "Puma: stale PID file ($pid); leaving it for manual inspection"
    return 0
  fi
  gitwo_puma_owned "$target" "$pid" || {
    gitwo_warn "Puma PID $pid could not be verified as belonging to $target"
    return 1
  }
  kill -TERM "$pid" || return 1
  for ((attempt=0; attempt<60; attempt++)); do
    if _gitwo_process_stopped "$pid"; then
      gitwo_ok "Puma stopped (PID $pid)"
      return 0
    fi
    sleep 0.1
  done
  gitwo_warn "Puma PID $pid did not stop after SIGTERM; no force-kill attempted"
  return 1
}

# Ensure a stopped-workspace check never creates new port allocations.
gitwo_redis_process_status() {
  local target="$1" mode="$2" port status
  if ! gitwo_runtime_existing_load "$target"; then
    printf 'not allocated\n'
    return 0
  fi
  port="$(_gitwo_redis_port "$mode")"
  if ! command -v redis-cli >/dev/null 2>&1; then
    printf 'unknown (redis-cli not installed)\n'
  elif [[ "$(_gitwo_redis_cli "$port" PING 2>/dev/null || true)" != PONG ]]; then
    printf 'stopped\n'
  elif _gitwo_redis_is_owned "$target" "$mode" "$port"; then
    printf 'running (127.0.0.1:%s)\n' "$port"
  else
    printf 'foreign/unknown (127.0.0.1:%s)\n' "$port"
  fi
}

# Discover Sidekiq instances only by process identity AND current working directory.
# No Sidekiq PID files or application patches required.
gitwo_sidekiq_pids() {
  local target="$1" pid command cwd
  while read -r pid command; do
    [[ "$pid" =~ ^[1-9][0-9]*$ && "$command" == *sidekiq* ]] || continue
    # Ignore shells running a command containing the word sidekiq.
    [[ "$command" == *'bundle exec sidekiq'* || "$command" == *'/sidekiq'* || "$command" == sidekiq* ]] || continue
    cwd="$(_gitwo_process_cwd "$pid" 2>/dev/null || true)"
    [[ "$cwd" == "$target" ]] || continue
    printf '%s\n' "$pid"
  done < <(ps -axo pid=,command= 2>/dev/null)
}

gitwo_sidekiq_stop() {
  local target="$1" pid attempt
  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    kill -TERM "$pid" || return 1
    for ((attempt=0;attempt<60;attempt++)); do
      if _gitwo_process_stopped "$pid"; then break; fi
      sleep 0.1
    done
    if ! _gitwo_process_stopped "$pid"; then
      gitwo_warn "Sidekiq PID $pid did not stop; no force-kill attempted"
      return 1
    fi
    gitwo_ok "Sidekiq stopped (PID $pid)"
  done < <(gitwo_sidekiq_pids "$target")
}
