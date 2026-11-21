#!/usr/bin/env bash
# Human or JSON inventory of linked Git worktrees. Read-only.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/_common.sh"
if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then
  printf 'Usage: gitwo list [--json]\nList linked Git worktrees.\n'
  exit 0
fi
[[ $# -eq 0 || ( $# -eq 1 && "$1" == --json ) ]] || gitwo_die 'Usage: gitwo list [--json]'
gitwo_check_source
if [[ "${1:-}" != --json ]]; then
  git -C "$GITWO_SOURCE" --no-pager worktree list
  exit 0
fi
git -C "$GITWO_SOURCE" worktree list --porcelain | GITWO_JSON_ROOT="$GITWO_ROOT" GITWO_JSON_SOURCE="$GITWO_SOURCE" GITWO_JSON_STATE="$GITWO_STATE" ruby -rjson -e '
    root=ENV.fetch("GITWO_JSON_ROOT")
    source=ENV.fetch("GITWO_JSON_SOURCE")
    state=ENV.fetch("GITWO_JSON_STATE")
    list=STDIN.read.split(/\n\s*\n/).map do |block|
      data={}
      block.lines.each do |line|
        key,value=line.strip.split(" ",2)
        data[key]=value || true if key
      end
      path=data["worktree"]
      next unless path
      slug=File.basename(path)
      created=File.join(state,slug+".created-at")
      timestamp=File.file?(created) && !File.symlink?(created) ? File.read(created).strip : nil
      {"workspace"=>slug,"path"=>path,"branch"=>data["branch"]&.sub(%r{\Arefs/heads/}, ""),
        "head"=>data["HEAD"],"base"=>path==source,"created_at"=>timestamp}
    end
    puts JSON.pretty_generate(list.compact)
  '
