#!/usr/bin/env bash
# Test preservation of existing, ignored application ENV conventions.
set -euo pipefail
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/gitwo-application-env.XXXXXXXX")"
trap 'rm -rf -- "$tmp"' EXIT
source_root="$tmp/app"
target_root="$tmp/worktree"
mkdir -p "$source_root/config/credentials"
git init -q -b main "$source_root"
git -C "$source_root" config user.name 'Gitwo fixture'
git -C "$source_root" config user.email fixture@example.invalid

cat > "$source_root/.gitignore" <<'IGNORE'
.env
.env.local
.env.development
.env.development.local
.env.test.local
.envrc
.env.staging
.env.production
config/master.key
config/credentials/*.key
IGNORE

printf 'tracked=test\n' > "$source_root/.env.test"
printf 'primary=yes\n' > "$source_root/README.txt"
git -C "$source_root" add .gitignore .env.test README.txt
git -C "$source_root" commit -qm 'Create application with team ENV conventions'

printf 'DEVELOPMENT_TOKEN=local-only\n' > "$source_root/.env"
printf 'DEVELOPMENT_ONLY=1\n' > "$source_root/.env.development"
printf 'DEVELOPMENT_LOCAL=1\n' > "$source_root/.env.development.local"
printf 'TEST_LOCAL=1\n' > "$source_root/.env.test.local"
printf '# Developer-owned direnv rules\nexport APP_ENV_STYLE=legacy\n' > "$source_root/.envrc"
printf 'private-master-key\n' > "$source_root/config/master.key"
printf 'private-dev-key\n' > "$source_root/config/credentials/development.key"
printf 'private-test-key\n' > "$source_root/config/credentials/test.key"
printf 'STAGING_SECRET=never-copy\n' > "$source_root/.env.staging"
printf 'PRODUCTION_SECRET=never-copy\n' > "$source_root/.env.production"
ln -s .env "$source_root/.env.local"

git -C "$source_root" worktree add -q -b feature/env-preservation-1 "$target_root"
gitwo_log() { printf '[INFO] %s\n' "$*" >&2; }
gitwo_warn() { printf '[WARN] %s\n' "$*" >&2; }
gitwo_ok() { printf '[OK] %s\n' "$*" >&2; }
gitwo_die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }
source "$here/application-env.sh"

# Detect file names and ownership without opening their secret contents.
ruby "$here/detect.rb" "$source_root" --json > "$tmp/inventory.json"
ruby -rjson -e '
  files = JSON.parse(File.read(ARGV.fetch(0))).dig("detected", "application_env", "value")
  actual = files.to_h { |entry| [entry.fetch("path"), entry.fetch("ownership")] }
  abort actual.inspect unless actual.fetch(".env") == "ignored" &&
    actual.fetch(".env.test") == "tracked" &&
    actual.fetch(".env.test.local") == "ignored" &&
    actual.fetch(".envrc") == "ignored" &&
    actual.fetch(".env.local") == "symlink"
' "$tmp/inventory.json"

gitwo_application_env_copy_ignored "$source_root" "$target_root"
for file in .env .env.development .env.development.local .env.test.local .envrc \
  config/master.key config/credentials/development.key config/credentials/test.key; do
  cmp "$source_root/$file" "$target_root/$file"
  ruby -e 'abort "Not private" unless (File.stat(ARGV.fetch(0)).mode & 0777) == 0600' "$target_root/$file"
done
[[ "$(cat "$target_root/.env.test")" == 'tracked=test' ]]
[[ ! -e "$target_root/.env.local" ]]
[[ ! -e "$target_root/.env.staging" ]]
[[ ! -e "$target_root/.env.production" ]]
[[ -z "$(git -C "$source_root" status --porcelain --untracked-files=all)" ]]
[[ -z "$(git -C "$target_root" status --porcelain --untracked-files=all)" ]]

# Existing files, including a developer-owned .envrc, must remain untouched.
printf 'custom value\n' > "$target_root/.envrc"
gitwo_application_env_copy_ignored "$source_root" "$target_root"
[[ "$(cat "$target_root/.envrc")" == 'custom value' ]]

# A non-ignored local file does not become an untracked file in a worktree.
printf 'untracked-local=1\n' > "$source_root/.env.example"
source_root_ignored_before="$(git -C "$source_root" status --porcelain --untracked-files=all | grep -c .env.example || true)"
[[ "$source_root_ignored_before" == 1 ]]

# Do not traverse a symlinked credentials directory when copying private keys.
second="$tmp/worktree-second"
git -C "$source_root" worktree add -q -b feature/env-preservation-2 "$second"
mkdir -p "$second/config"
rm -rf "$second/config/credentials"
ln -s "$tmp" "$second/config/credentials"
if (gitwo_application_env_copy_ignored "$source_root" "$second") >"$tmp/unsafe.log" 2>&1; then
  echo 'Symlinked credentials directory unexpectedly accepted' >&2
  exit 1
fi
grep -Fq 'symlinked credentials directory' "$tmp/unsafe.log"
[[ ! -f "$tmp/development.key" ]]

# Discover local Compose variants and multiple Dev Container profiles without
# executing Docker, following symlinks or parsing arbitrary project hooks.
mkdir -p "$source_root/.devcontainer/rails" "$source_root/.devcontainer/other"
printf 'services: {}\n' > "$source_root/compose.local.yml"
printf 'services: {}\n' > "$source_root/docker-compose.development.yaml"
printf 'services: {}\n' > "$source_root/.devcontainer/docker-compose.yml"
printf '{"name":"rails"}\n' > "$source_root/.devcontainer/rails/devcontainer.json"
printf '{"name":"root"}\n' > "$source_root/.devcontainer/devcontainer.json"
ln -s "$tmp" "$source_root/.devcontainer/other/malicious"
ln -s /dev/null "$source_root/compose.dev.yml"
ruby "$here/detect.rb" "$source_root" --json > "$tmp/developer-environments.json"
ruby -rjson -e '
  data = JSON.parse(File.read(ARGV.fetch(0))).fetch("detected")
  compose = data.fetch("compose_files").fetch("value")
  abort "missing development/local Compose" unless compose.include?("compose.local.yml") &&
    compose.include?("docker-compose.development.yaml")
  abort "followed symlinked Compose" if compose.include?("compose.dev.yml")
  containers = data.fetch("devcontainer_files").fetch("value")
  abort "missing Dev Container profiles" unless containers.include?(".devcontainer/devcontainer.json") &&
    containers.include?(".devcontainer/rails/devcontainer.json")
  compose_in_container = data.fetch("devcontainer_compose_files").fetch("value")
  abort "missing Dev Container Compose file" unless compose_in_container.include?(".devcontainer/docker-compose.yml")
' "$tmp/developer-environments.json"
# Source and target worktrees can diverge in .gitignore. Do not copy
# a developer-local secret into a newly unignored path on another branch.
third="$tmp/worktree-third"
git -C "$source_root" worktree add -q -b feature/ignore-drift "$third"
ruby - "$third/.gitignore" <<'RUBY'
path = ARGV.fetch(0)
File.write(path, File.readlines(path).reject { |line| line.strip == '.env' }.join)
RUBY
if git -C "$third" check-ignore -q .env; then
  echo 'Fixture .env must be visible in target branch' >&2; exit 1
fi
gitwo_application_env_copy_ignored "$source_root" "$third" > "$tmp/drift.log" 2>&1
[[ ! -e "$third/.env" ]]
grep -Fq 'Not copying application file into non-ignored worktree path: .env' "$tmp/drift.log"

printf '[PASS] app ENV preservation, Compose/Dev Container discovery, safe symlink handling\n'
