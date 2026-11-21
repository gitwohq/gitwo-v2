#!/usr/bin/env bash
# Gitwo-owned, per-workspace Compose PostgreSQL and Redis services.
# No application compose.yaml file is read, executed, or rewritten.
gitwo_compose_dir() { printf '%s/runtime/%s/compose\n' "$GITWO_STATE" "$(basename "$1")"; }
gitwo_compose_name() {
  local suffix
  suffix="$(printf %s "$1" | ruby -rdigest -e 'print Digest::SHA256.hexdigest(STDIN.read)[0,12]')"
  printf 'gitwo_%s_%s\n' "$GITWO_PROJECT_ID" "$suffix"
}
gitwo_compose_apply() {
  [[ "$GITWO_SERVICES_BACKEND" == compose ]] || return 0
  local path="$1" dir pg password
  dir="$(gitwo_compose_dir "$path")"
  [[ -f "$dir/pg.port" && ! -L "$dir/pg.port" && -f "$dir/pg.password" && ! -L "$dir/pg.password" ]] ||
    gitwo_die 'Managed Compose database is not prepared; use gitwo services up'
  pg="$(cat "$dir/pg.port")"
  password="$(cat "$dir/pg.password")"
  [[ "$pg" =~ ^[0-9]{4,5}$ && "$pg" -ge 1024 && "$pg" -le 65535 ]] || gitwo_die 'Invalid Compose PostgreSQL port'
  [[ "$password" =~ ^[0-9a-f]{48}$ ]] || gitwo_die 'Invalid Compose password'
  GITWO_DB_HOST=127.0.0.1
  GITWO_DB_PORT="$pg"
  PGPASSWORD="$password"
  export GITWO_DB_HOST GITWO_DB_PORT PGPASSWORD
}
gitwo_compose_cli() {
  local path="$1" dir; shift
  dir="$(gitwo_compose_dir "$path")"
  [[ -f "$dir/compose.yml" && ! -L "$dir/compose.yml" && -f "$dir/compose.env" && ! -L "$dir/compose.env" ]] ||
    gitwo_die 'Missing or unsafe managed Compose configuration'
  docker compose --project-name "$(gitwo_compose_name "$path")" -f "$dir/compose.yml" --env-file "$dir/compose.env" "$@"
}
gitwo_compose_prepare() {
  [[ "$GITWO_SERVICES_BACKEND" == compose ]] || return 0
  local path="$1" dir lock pg i password
  gitwo_need docker
  docker compose version >/dev/null 2>&1 || gitwo_die 'Docker Compose V2 is required'
  source "$GITWO_DIR/_runtime.sh"
  gitwo_runtime_load "$path"
  dir="$(gitwo_compose_dir "$path")"
  [[ ! -L "$dir" ]] || gitwo_die 'Unsafe Compose state symlink'
  mkdir -p "$dir"; chmod 700 "$dir"
  if [[ ! -f "$dir/pg.port" ]]; then
    lock="$GITWO_GLOBAL_STATE_ROOT/.compose-port-lock"
    for ((i=0;i<100;i++)); do
      if mkdir "$lock" 2>/dev/null; then break; fi
      sleep .1
    done
    [[ "$i" -lt 100 ]] || gitwo_die 'Compose port reservation lock busy'
    if [[ ! -f "$dir/pg.port" ]]; then
      for ((pg=23000;pg<=25999;pg++)); do
        if ! grep -lqx "$pg" "$GITWO_GLOBAL_STATE_ROOT"/projects/*/runtime/*/compose/pg.port >/dev/null 2>&1 &&
           _gitwo_runtime_port_free "$pg"; then break; fi
      done
      [[ "$pg" -le 25999 ]] || gitwo_die 'No free Compose PostgreSQL port'
      (umask 077; set -C; printf '%s\n' "$pg" > "$dir/pg.port") || gitwo_die 'Compose port collision'
    fi
    rmdir "$lock"
  fi
  if [[ ! -f "$dir/pg.password" ]]; then
    password="$(ruby -rsecurerandom -e 'print SecureRandom.hex(24)')"
    (umask 077; set -C; printf '%s\n' "$password" > "$dir/pg.password") || gitwo_die 'Compose password collision'
  fi
  gitwo_compose_apply "$path"
  if [[ ! -e "$dir/compose.yml" ]]; then
    (umask 077; set -C; cat > "$dir/compose.yml" <<'YAML'
# Generated and owned by Gitwo. Not an application Compose file.
services:
  postgres:
    image: postgres:16
    environment:
      POSTGRES_USER: $GITWO_COMPOSE_DB_USER
      POSTGRES_PASSWORD: $GITWO_COMPOSE_DB_PASSWORD
      POSTGRES_DB: postgres
    ports:
      - "127.0.0.1:$GITWO_COMPOSE_PG_PORT:5432"
    volumes:
      - postgres-data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U $$POSTGRES_USER -d postgres"]
      interval: 3s
      timeout: 3s
      retries: 30
  redis-dev:
    image: redis:7
    ports:
      - "127.0.0.1:$GITWO_COMPOSE_REDIS_DEV_PORT:6379"
  redis-test:
    image: redis:7
    ports:
      - "127.0.0.1:$GITWO_COMPOSE_REDIS_TEST_PORT:6379"
volumes:
  postgres-data:
YAML
    ) || gitwo_die 'Cannot create managed Compose file'
  fi
  [[ -f "$dir/compose.yml" && ! -L "$dir/compose.yml" ]] || gitwo_die 'Unsafe managed Compose file'
  (umask 077; printf 'GITWO_COMPOSE_DB_USER=%s\nGITWO_COMPOSE_DB_PASSWORD=%s\nGITWO_COMPOSE_PG_PORT=%s\nGITWO_COMPOSE_REDIS_DEV_PORT=%s\nGITWO_COMPOSE_REDIS_TEST_PORT=%s\n' \
    "$GITWO_DB_USER" "$PGPASSWORD" "$GITWO_DB_PORT" "$REDIS_DEV_PORT" "$REDIS_TEST_PORT" > "$dir/compose.env")
}
gitwo_compose_up() {
  [[ "$GITWO_SERVICES_BACKEND" == compose ]] || return 0
  gitwo_compose_prepare "$1"
  gitwo_compose_cli "$1" up -d --wait postgres redis-dev redis-test || gitwo_die 'Managed Compose services did not become healthy'
}
gitwo_compose_down() {
  [[ "$GITWO_SERVICES_BACKEND" == compose ]] || return 0
  gitwo_need docker
  gitwo_compose_cli "$1" down || gitwo_die 'Failed to stop owned Compose services; volumes preserved'
}
