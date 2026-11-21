#!/usr/bin/env bash
# No Docker daemon needed: validate safe Compose generation with a fake CLI.
set -euo pipefail
here="$(cd -- "$(dirname -- "$0")" && pwd -P)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
export HOME="$tmp/home" GITWO_GLOBAL_STATE_ROOT="$tmp/state"
mkdir -p "$HOME" "$tmp/bin" "$tmp/app"
git -C "$tmp/app" init -q -b main
git -C "$tmp/app" config user.email test@example.invalid
git -C "$tmp/app" config user.name Test
printf 'fixture\n' > "$tmp/app/README"
git -C "$tmp/app" add README
git -C "$tmp/app" commit -qm fixture
mkdir -p "$tmp/worktrees"
git -C "$tmp/app" worktree add -q -b experiment/develop-1 "$tmp/worktrees/develop-1"
git -C "$tmp/app" worktree add -q -b experiment/develop-2 "$tmp/worktrees/develop-2"
export GITWO_WORKSPACES_ROOT="$tmp/worktrees"
# Worktrees from independent directories must share the same Gitwo state.
mkdir -p "$tmp/worktrees"
cat > "$tmp/app/compose.yaml" <<'YAML'
services:
  dangerous-app-service:
    image: alpine
    command: echo never-run-this
YAML
ruby "$here/detect.rb" "$tmp/app" --json > "$tmp/detect.json"
ruby -rjson -e 'd=JSON.parse(File.read(ARGV[0])); abort unless d.dig("detected","compose_files","value")==["compose.yaml"]; abort unless d.dig("suggested","services","backend")=="native"' "$tmp/detect.json"
cat > "$tmp/app/gitwo.yml" <<'YAML'
version: 1
project:
  adapter: rails-standard
  source: app
  base_branch: main
services:
  backend: compose
YAML
ruby "$here/config.rb" validate "$tmp/app/gitwo.yml" >/dev/null
cat > "$tmp/bin/docker" <<'BASH'
#!/usr/bin/env bash
echo "$*" >> "$GITWO_FAKE_DOCKER_LOG"
exit 0
BASH
chmod +x "$tmp/bin/docker"
export PATH="$tmp/bin:$PATH" GITWO_PROJECT_ROOT="$tmp/app" GITWO_FAKE_DOCKER_LOG="$tmp/docker.log"
bash "$here/services.sh" up develop-1
bash "$here/services.sh" up develop-2
first="$(find "$tmp/state" -path '*/develop-1/compose/pg.port' -print -quit)"
second="$(find "$tmp/state" -path '*/develop-2/compose/pg.port' -print -quit)"
[[ -s "$first" && -s "$second" ]]
[[ "$(cat "$first")" != "$(cat "$second")" ]]
root="$(dirname "$first")"
[[ -s "$root/pg.password" && -s "$root/compose.env" && -s "$root/compose.yml" ]]
grep -q '127.0.0.1:' "$root/compose.yml"
grep -q 'postgres:16' "$root/compose.yml"
grep -q 'redis:7' "$root/compose.yml"
! grep -q 'dangerous-app-service' "$tmp/docker.log"
! grep -q "$tmp/app/compose.yaml" "$tmp/docker.log"
bash "$here/services.sh" down develop-1
! grep -q -- 'down -v' "$tmp/docker.log"
printf '[PASS] Compose detection, safe file isolation, unique ports and volume-preserving down\n'
