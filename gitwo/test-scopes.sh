#!/usr/bin/env bash
# Scope regression: local init never changes the application repository.
set -euo pipefail
here="$(cd -- "$(dirname -- "$0")" && pwd -P)"
tmp="$(mktemp -d "$HOME/gitwo-scopes.XXXXXXXX")"
trap 'rm -rf -- "$tmp"' EXIT
export HOME="$tmp/home" XDG_CONFIG_HOME="$tmp/home/.config"
mkdir -p "$HOME" "$tmp/bin" "$tmp/projects"
cp "$here/../bin/gitwo" "$tmp/bin/gitwo"
# The installed entry point expects ./share/gitwo relative to the bin directory.
mkdir -p "$tmp/share"
ln -s "$here" "$tmp/share/gitwo"
chmod +x "$tmp/bin/gitwo"
export PATH="$tmp/bin:$PATH"
make_project() {
  project="$tmp/projects/$1"
  git init -q -b main "$project"
  git -C "$project" config user.email local@example.invalid
  git -C "$project" config user.name Local
  mkdir -p "$project/config"
  printf "source 'https://rubygems.org'\ngem 'rails'\ngem 'pg'\n" > "$project/Gemfile"
  printf '# Rails app\n' > "$project/config/application.rb"
  printf "default: &default\n  adapter: postgresql\n" > "$project/config/database.yml"
  git -C "$project" add .
  git -C "$project" commit -qm initial
  git init -q --bare "$tmp/projects/$1.git"
  git -C "$project" remote add origin "$tmp/projects/$1.git"
  git -C "$project" push -q -u origin main
}
make_project alpha
cd "$project"
original="$(git status --porcelain --untracked-files=all)"
gitwo init --yes > "$tmp/local.log"
expected="$(ruby "$here/config-location.rb" local "$project")"
[[ -f "$expected" && ! -e "$project/gitwo.yml" ]]
[[ "$(git status --porcelain --untracked-files=all)" == "$original" ]]
[[ "$(gitwo config path)" == "$expected" ]]
[[ "$(gitwo config scope)" == local ]]
ruby "$here/team-onboard.rb" --project="$project" --check --scope=local > "$tmp/local-check"
ruby "$here/team-onboard.rb" --project="$project" --check --json --scope=local > "$tmp/local.json"
ruby -rjson -e 'j=JSON.parse(File.read(ARGV[0])); abort j.inspect unless j["status"]=="ok" && j["scope"]=="local"' "$tmp/local.json"
# No-setup workspaces still work with a private config and no project YAML.
gitwo new develop --no-setup > "$tmp/workspace.log" 2> "$tmp/new.err"
[[ -d "$tmp/projects/.gitwo-workspaces/alpha/develop-1" ]]
gitwo init --yes > "$tmp/reinit.log"
grep -Fq 'Existing configuration validated' "$tmp/reinit.log"

# A preview must not create scope markers or project files.
make_project beta
cd "$project"
gitwo init --dry-run > "$tmp/preview.log"
grep -Fq 'Scope: local' "$tmp/preview.log"
grep -Fq "$project" "$tmp/preview.log"
[[ ! -d "$XDG_CONFIG_HOME/gitwo" && ! -e "$project/gitwo.yml" ]] || {
  # The directory may exist due to the first project, but beta must have no config.
  [[ ! -e "$(ruby "$here/config-location.rb" local "$project")" ]]
}
custom="$XDG_CONFIG_HOME/custom/gitwo-beta.yml"
gitwo init --yes --scope=local --output="$custom" > "$tmp/custom.log"
[[ -f "$custom" && "$(gitwo config path)" == "$custom" ]]
[[ ! -e "$project/gitwo.yml" ]]
[[ -f "$custom" && "$(stat -c %a "$custom" 2>/dev/null || stat -f %Lp "$custom")" == 600 ]]
if gitwo init --yes --scope=local --output="$project/private.yml" > "$tmp/bad.out" 2> "$tmp/bad.err"; then
  echo 'Local output inside project was accepted' >&2; exit 1
fi
[[ ! -e "$project/private.yml" ]]

# Switching to team creates an untracked repo file only when requested.
gitwo init --yes --scope=team > "$tmp/team.log"
[[ -f "$project/gitwo.yml" ]]
[[ "$(gitwo config path)" == "$project/gitwo.yml" ]]
[[ "$(gitwo config scope)" == team ]]
if ruby "$here/team-onboard.rb" --scope=team --project="$project" --check > /dev/null 2>&1; then
  echo 'Uncommitted team config was accepted' >&2; exit 1
fi
git -C "$project" add gitwo.yml
git -C "$project" commit -qm 'Team opts in to Gitwo'
ruby "$here/team-onboard.rb" --scope=team --project="$project" --check >/dev/null
gitwo config use local > "$tmp/activated.log"
[[ "$(gitwo config path)" == "$custom" ]]
[[ "$(gitwo config scope)" == local ]]
gitwo config use team > /dev/null
[[ "$(gitwo config path)" == "$project/gitwo.yml" ]]

# Independent local clones must not share the same config path.
make_project alpha
[[ "$(ruby "$here/config-location.rb" local "$project")" != "$expected" ]]
printf '[PASS] local/team scopes, safe config paths, idempotent init and explicit activation\n'
