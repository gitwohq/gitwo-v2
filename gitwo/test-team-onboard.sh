#!/usr/bin/env bash
# Offline team onboarding contract: portable clones, CI read-only and safe failures.
set -euo pipefail
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/gitwo-team-onboard.XXXXXXXX")"
trap 'rm -rf -- "$tmp"' EXIT
export HOME="$tmp/home" XDG_CONFIG_HOME="$tmp/home/.config"
mkdir -p "$HOME" "$tmp/work" "$tmp/work/renamed-clone/config"
project="$tmp/work/renamed-clone"
git -C "$project" init -q -b main
git -C "$project" config user.email team@example.invalid
git -C "$project" config user.name Team
cat > "$project/gitwo.yml" <<'YAML'
version: 1
project:
  adapter: rails-standard
  source: canonical-app
  base_branch: main
git:
  workflow: github-flow
issues:
  provider: none
  credential: default
framework:
  name: rails
  sidekiq: false
  redis: false
storage:
  dumps_directory: dumps
branches:
  feature_base: origin/main
  hotfix_base: origin/main
database:
  host: localhost
  port: 5432
  user: postgres
  prefix: canonical_app
  bootstrap: schema
services:
  backend: native
runtime:
  proxy: none
  domain: canonical-app
YAML
cat > "$project/config/database.yml" <<'YAML'
development:
  adapter: postgresql
  database: canonical_app_development
test:
  adapter: postgresql
  database: canonical_app_test
YAML
printf 'fixture\n' > "$project/README.md"
git -C "$project" add gitwo.yml config/database.yml README.md
git -C "$project" commit -qm 'Commit shared team configuration'
git init -q --bare "$tmp/work/origin.git"
git -C "$project" remote add origin "$tmp/work/origin.git"
git -C "$project" push -q -u origin main
project_sha_before="$(git -C "$project" status --porcelain --untracked-files=all)"

# Team CI check must neither need Docker nor modify repo or HOME.
ruby "$here/team-onboard.rb" --project="$project" --check --json > "$tmp/check.json"
ruby -rjson -e '
  result = JSON.parse(File.read(ARGV.fetch(0)))
  abort result.inspect unless result["status"] == "ok" && result["mode"] == "check"
  abort "missing committed config check" unless result["checks"].any? { |c| c["id"] == "committed_config" && c["status"] == "ok" }
  abort "clone folder falsely rejected" unless result["checks"].any? { |c| c["id"] == "checkout_name" && c["status"] == "ok" }
' "$tmp/check.json"
[[ "$(git -C "$project" status --porcelain --untracked-files=all)" == "$project_sha_before" ]]
[[ ! -e "$HOME/.local/state/gitwo" ]]
# Pre-existing configs can be reused, even from a different local clone name.
ruby "$here/onboard.rb" init --project="$project" --yes > "$tmp/reuse.out"
grep -Fq 'Existing configuration validated' "$tmp/reuse.out"
GITWO_PROJECT_ROOT="$project" bash "$here/config.sh" validate > "$tmp/config-validation.out"

# No local setup is needed for the portable checkout naming contract.
workspace="$(GITWO_PROJECT_ROOT="$project" bash "$here/new.sh" develop --no-setup 2>"$tmp/new.err")"
[[ "$workspace" == "$tmp/work/.gitwo-workspaces/renamed-clone/develop-1" ]]
[[ "$(git -C "$workspace" branch --show-current)" == experiment/develop-1 ]]
[[ "$(git -C "$project" branch --show-current)" == main ]]

# The CI check refuses untracked or symlinked team configuration.
git -C "$project" rm --cached -q gitwo.yml
if ruby "$here/team-onboard.rb" --project="$project" --check > "$tmp/untracked.log" 2>&1; then
  echo 'Expected uncommitted shared configuration to be refused' >&2; exit 1
fi
git -C "$project" reset -q HEAD gitwo.yml
mv "$project/gitwo.yml" "$tmp/safe-gitwo.yml"
ln -s "$tmp/safe-gitwo.yml" "$project/gitwo.yml"
if ruby "$here/team-onboard.rb" --project="$project" --check > "$tmp/symlink.log" 2>&1; then
  echo 'Expected symlinked shared configuration refusal' >&2; exit 1
fi
rm "$project/gitwo.yml"
mv "$tmp/safe-gitwo.yml" "$project/gitwo.yml"

# Strict YAML parser must reject executable object tags without evaluation.
cp "$project/gitwo.yml" "$tmp/original.yml"
printf '%s\n' '--- !ruby/object:Kernel {}' > "$project/gitwo.yml"
if ruby "$here/team-onboard.rb" --project="$project" --check > "$tmp/malicious.log" 2>&1; then
  echo 'Unsafe YAML was accepted' >&2; exit 1
fi
cp "$tmp/original.yml" "$project/gitwo.yml"
if ruby "$here/team-onboard.rb" --project="$project" --check --setup > "$tmp/invalid.log" 2>&1; then
  echo 'Conflicting check/setup options were accepted' >&2; exit 1
fi
ruby "$here/team-onboard.rb" --project="$project" --check > "$tmp/recovered.log"
[[ "$(git -C "$project" status --porcelain --untracked-files=all)" == "$project_sha_before" ]]
printf '[PASS] team onboarding: committed config, renamed clone, read-only CI, strict YAML and safe refusals\n'
