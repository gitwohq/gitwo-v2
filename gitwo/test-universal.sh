#!/usr/bin/env bash
# Regression test of independent projects using real temporary Git repositories.
set -euo pipefail
source_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/gitwo-projects.XXXXXXXX")"
trap 'rm -rf -- "$tmp"' EXIT
export HOME="$tmp/home" XDG_CONFIG_HOME="$tmp/home/.config"
mkdir -p "$HOME" "$tmp/work" "$tmp/prefix/bin" "$tmp/prefix/share/gitwo"
cp -R "$source_dir/." "$tmp/prefix/share/gitwo/"
cp "$source_dir/../bin/gitwo" "$tmp/prefix/bin/gitwo"
chmod +x "$tmp/prefix/bin/gitwo"
export PATH="$tmp/prefix/bin:$PATH"
for project in alpha beta; do
  git init -q --bare "$tmp/work/$project-remote.git"
  git init -q -b main "$tmp/work/$project"
  git -C "$tmp/work/$project" config user.email fixture@example.com
  git -C "$tmp/work/$project" config user.name Fixture
  mkdir -p "$tmp/work/$project/config" "$tmp/work/$project/db"
  printf "source 'https://rubygems.org'\ngem 'rails'\ngem 'pg'\n" > "$tmp/work/$project/Gemfile"
  printf '    rails (8.0.0)\n    pg (1.5.0)\n' > "$tmp/work/$project/Gemfile.lock"
  printf '# fixture\n' > "$tmp/work/$project/config/application.rb"
  printf '# fixture\n' > "$tmp/work/$project/db/schema.rb"
  git -C "$tmp/work/$project" add .
  git -C "$tmp/work/$project" commit -qm initial
  git -C "$tmp/work/$project" remote add origin "$tmp/work/$project-remote.git"
  git -C "$tmp/work/$project" push -q -u origin main
  cd "$tmp/work/$project"
  gitwo init --yes > /dev/null
  [[ -s gitwo.yml ]]
  [[ "$(ruby -ryaml -e 'puts YAML.load_file("gitwo.yml").dig("issues", "provider")')" == none ]]
  [[ "$(ruby -ryaml -e 'puts YAML.load_file("gitwo.yml").dig("database", "bootstrap")')" == schema ]]
  gitwo config validate >/dev/null
  gitwo new feature ENG-42 --title "Fix $project" --no-setup >/dev/null 2>/dev/null
  gitwo new develop --no-setup >/dev/null 2>/dev/null
  [[ -d "$tmp/work/.gitwo-workspaces/$project/eng-42-feature" ]]
  [[ -d "$tmp/work/.gitwo-workspaces/$project/develop-1" ]]
  gitwo list --json | grep -q "eng-42-feature"
  gitwo doctor >/dev/null
  gitwo init --yes > "$tmp/reinit.log"
  grep -q 'Existing configuration validated' "$tmp/reinit.log"
  [[ "$(git -C "$tmp/work/$project" branch --show-current)" == main ]]
done
# Branch refs are evidence of a probable GitFlow configuration, not proof.
git -C "$tmp/work/beta" branch develop
git -C "$tmp/work/beta" push -q origin develop
GITWO_PROJECT_ROOT="$tmp/work/beta" gitwo detect --json > "$tmp/beta-detection.json"
ruby -rjson -e 'd=JSON.parse(File.read(ARGV.fetch(0))); abort "workflow not inferred" unless d.dig("inferred", "workflow", "value")=="gitflow"' "$tmp/beta-detection.json"
[[ "$(ruby -e 'dir=ARGV.fetch(0); puts Dir.children(dir).count { |name| File.directory?(File.join(dir,name)) }' "$HOME/.local/state/gitwo/projects")" == 2 ]]
# An invocation outside a Git repo does not pick a project silently.
cd "$tmp/work"
if gitwo list > /dev/null 2> "$tmp/error"; then echo 'Expected ambiguous project rejection' >&2; exit 1; fi
grep -q 'project not found' "$tmp/error"
GITWO_PROJECT_ROOT="$tmp/work/alpha" gitwo list --json | grep -q 'eng-42-feature'
# Global state is not accidentally written into either Git repo.
[[ ! -e "$tmp/work/alpha/.state" && ! -e "$tmp/work/beta/.state" ]]
# Sequential creation lock avoids colliding names, including concurrent callers.
cd "$tmp/work/alpha"
gitwo new develop --no-setup >/dev/null 2> "$tmp/parallel-1.err" & pid_a=$!
gitwo new develop --no-setup >/dev/null 2> "$tmp/parallel-2.err" & pid_b=$!
wait "$pid_a"; wait "$pid_b"
[[ -d "$tmp/work/.gitwo-workspaces/alpha/develop-2" && -d "$tmp/work/.gitwo-workspaces/alpha/develop-3" ]]
printf '[PASS] two project roots, independent metadata and worktrees, idempotent init, concurrency\n'
