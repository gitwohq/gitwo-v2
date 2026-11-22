#!/usr/bin/env bash
# No Docker daemon needed: validate safe Compose generation with a fake CLI.
set -euo pipefail
here="$(cd -- "$(dirname -- "$0")" && pwd -P)"
tmp="$(mktemp -d)"
# macOS /var is a symlink to /private/var; compare canonical paths.
tmp="$(cd -- "$tmp" && pwd -P)"
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
# Repeated startup must reuse the same credentials and ports.
original_env="$(cat "$root/compose.env")"
original_password="$(cat "$root/pg.password")"
bash "$here/services.sh" up develop-1
[[ "$(cat "$root/compose.env")" == "$original_env" ]]
[[ "$(cat "$root/pg.password")" == "$original_password" ]]

# Changing a service user would invalidate a persisted PostgreSQL volume.
if GITWO_DB_USER=unexpected_user bash "$here/services.sh" up develop-1 > "$tmp/change.out" 2> "$tmp/change.err"; then
  echo 'Expected changed Compose settings to be rejected' >&2
  exit 1
fi
grep -Fq 'refusing to rewrite persisted PostgreSQL credentials or ports' "$tmp/change.err"
[[ "$(cat "$root/compose.env")" == "$original_env" ]]

# A malicious or accidental symlink must never be followed or overwritten.
printf 'foreign-file-must-survive\n' > "$tmp/foreign.env"
mv "$root/compose.env" "$root/compose.env.saved"
ln -s "$tmp/foreign.env" "$root/compose.env"
if bash "$here/services.sh" up develop-1 > "$tmp/symlink.out" 2> "$tmp/symlink.err"; then
  echo 'Expected symlinked Compose environment to be rejected' >&2
  exit 1
fi
grep -Fq 'Unsafe managed Compose environment file' "$tmp/symlink.err"
[[ "$(cat "$tmp/foreign.env")" == foreign-file-must-survive ]]
rm "$root/compose.env"
mv "$root/compose.env.saved" "$root/compose.env"

# A down operation must address only the selected Compose project.
project_first="$(awk '$1=="compose" && $2=="--project-name" && / up -d --wait postgres redis-dev redis-test$/ { print $3; exit }' "$tmp/docker.log")"
project_second="$(awk '$1=="compose" && $2=="--project-name" && / up -d --wait postgres redis-dev redis-test$/ { count++; if (count==2) { print $3; exit } }' "$tmp/docker.log")"
[[ -n "$project_first" && -n "$project_second" && "$project_first" != "$project_second" ]]
bash "$here/services.sh" down develop-1
[[ "$(awk '$1=="compose" && $2=="--project-name" && $NF=="down" { print $3 }' "$tmp/docker.log")" == "$project_first" ]]
bash "$here/services.sh" status develop-2
bash "$here/services.sh" down develop-2
[[ "$(awk '$1=="compose" && $2=="--project-name" && $NF=="down" { print $3 }' "$tmp/docker.log")" == "$(printf '%s\n%s' "$project_first" "$project_second")" ]]
! grep -q -- 'down -v' "$tmp/docker.log"
# A stopped Compose workspace must pass the safe, non-destructive removal preflight.
bash "$here/remove.sh" develop-1 --dry-run > "$tmp/remove-preview.log" 2>&1
[[ -d "$tmp/worktrees/develop-1" ]]
grep -Fq 'Dry run complete' "$tmp/remove-preview.log"
[[ -f "$root/pg.password" && -f "$root/pg.port" ]]
# Start three more workspaces concurrently. Locking must prevent PostgreSQL,
# Redis and web port collisions even when multiple terminals race to create them.
for number in 3 4 5; do
  git -C "$tmp/app" worktree add -q -b "experiment/develop-$number" "$tmp/worktrees/develop-$number"
done
pids=()
for number in 3 4 5; do
  bash "$here/services.sh" up "develop-$number" > "$tmp/parallel-$number.log" 2>&1 &
  pids+=("$!")
done
for pid in "${pids[@]}"; do wait "$pid"; done

pg_files=( "$tmp"/state/projects/*/runtime/develop-*/compose/pg.port )
[[ "${#pg_files[@]}" == 5 ]]
pg_unique="$(cat "${pg_files[@]}" | sort -u | wc -l | tr -d ' ')"
[[ "$pg_unique" == 5 ]] || { echo 'Concurrent Compose PostgreSQL port collision' >&2; exit 1; }
runtime_files=( "$tmp"/state/projects/*/runtime/develop-*.ports )
[[ "${#runtime_files[@]}" == 5 ]]
unique_runtime="$(cat "${runtime_files[@]}" | cut -d= -f2 | sort -u | wc -l | tr -d ' ')"
[[ "$unique_runtime" == 15 ]] || { echo 'Concurrent Redis/web port collision' >&2; exit 1; }
for number in 3 4 5; do
  bash "$here/services.sh" down "develop-$number"
done
! grep -q -- 'down -v' "$tmp/docker.log"
printf '[PASS] Compose isolation, immutable credentials, 5 concurrent workspaces, and safe lifecycle\n'
