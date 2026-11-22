#!/usr/bin/env bash
# Verify freeform features without an issue tracker or Git remote.
set -euo pipefail
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/gitwo-freeform.XXXXXXXX")"
trap 'rm -rf -- "$tmp"' EXIT
export HOME="$tmp/home" XDG_CONFIG_HOME="$tmp/home/.config"
mkdir -p "$HOME" "$tmp/project/config" "$tmp/project/db" "$tmp/bin" "$tmp/share"
git init -q -b main "$tmp/project"
git -C "$tmp/project" config user.name 'Gitwo fixture'
git -C "$tmp/project" config user.email fixture@example.invalid
printf "source 'https://rubygems.org'\ngem 'rails'\ngem 'pg'\n" > "$tmp/project/Gemfile"
printf '# fixture\n' > "$tmp/project/config/application.rb"
printf '# fixture\n' > "$tmp/project/db/schema.rb"
git -C "$tmp/project" add .
git -C "$tmp/project" commit -qm 'Create standalone project'
cp "$here/../bin/gitwo" "$tmp/bin/gitwo"
ln -s "$here" "$tmp/share/gitwo"
chmod +x "$tmp/bin/gitwo"
export PATH="$tmp/bin:$PATH"
cd "$tmp/project"

# Zero-configuration creation is possible before running gitwo init at all.
[[ -z "$(git remote)" ]]
zero="$(gitwo new feature 'Zero config' --no-setup)"
[[ "$(basename "$zero")" == zero-config-1 ]]
[[ "$(git -C "$zero" branch --show-current)" == feature/zero-config-1 ]]
[[ ! -e gitwo.yml ]]
[[ -z "$(git status --porcelain --untracked-files=all)" ]]

# Optional personal YAML initialization must work without origin.
gitwo init --scope=local --yes > "$tmp/init.log"
[[ -z "$(git status --porcelain --untracked-files=all)" ]]
[[ ! -e gitwo.yml ]]
[[ "$(ruby -ryaml -e 'puts YAML.safe_load_file(ARGV[0]).fetch("branches").fetch("feature_base")' "$(gitwo config path)")" == main ]]
gitwo config validate >/dev/null
gitwo new feature 'Improve search' --preview > "$tmp/preview.log"
grep -Fq 'Base:     main' "$tmp/preview.log"
grep -Fq 'feature/improve-search-1' "$tmp/preview.log"
[[ ! -d "$tmp/.gitwo-workspaces/project" ]]

first="$(gitwo new feature 'Improve search' --no-setup)"
[[ "$first" == "$tmp/.gitwo-workspaces/project/improve-search-1" ]]
[[ "$(git -C "$first" branch --show-current)" == feature/improve-search-1 ]]
[[ "$(gitwo checkout improve-search-1)" == "$first" ]]
second="$(gitwo new feature 'Improve search' --no-setup)"
[[ "$second" == "$tmp/.gitwo-workspaces/project/improve-search-2" ]]
[[ "$(git -C "$second" branch --show-current)" == feature/improve-search-2 ]]
gitwo list --json | grep -Fq 'feature/improve-search-2'
[[ "$(git -C "$tmp/project" branch --show-current)" == main ]]
[[ -z "$(git status --porcelain --untracked-files=all)" ]]

[[ "$(gitwo new feature 'Improve search' --resume --instance=1 --no-setup)" == "$first" ]]
if gitwo new feature --no-setup > "$tmp/noninteractive.out" 2> "$tmp/noninteractive.err"; then
  echo 'Expected missing feature name to fail without TTY' >&2; exit 1
fi
grep -Fq 'Enter a feature name' "$tmp/noninteractive.err"

# Exercise prompting from a real pseudo-terminal.
ruby -rpty -rtimeout - "$tmp/bin/gitwo" "$tmp/project" <<'RUBY'
cli, project = ARGV
Dir.chdir(project)
reader, writer, pid = PTY.spawn(cli, 'new', 'feature', '--no-setup')
output = ''
begin
  Timeout.timeout(20) do
    until output.include?('Feature name (no Jira or GitHub issue required)')
      output << reader.readpartial(4096)
    end
    writer.write("Improve dashboard\n")
    loop do
      begin
        output << reader.readpartial(4096)
      rescue EOFError, Errno::EIO
        break
      end
    end
  end
  status = Process.waitpid2(pid)[1]
  abort "Interactive named feature failed: #{output}" unless status.success?
ensure
  reader.close unless reader.closed?
  writer.close unless writer.closed?
end
RUBY
[[ -d "$tmp/.gitwo-workspaces/project/improve-dashboard-1" ]]

fake="$tmp/.gitwo-workspaces/project/foreign-1"
mkdir -p "$fake"
if gitwo checkout foreign-1 > /dev/null 2>&1; then
  echo 'Foreign path accepted as Gitwo worktree' >&2; exit 1
fi
printf '[PASS] named features: no origin, local YAML, sequential worktrees, TTY prompt\n'
