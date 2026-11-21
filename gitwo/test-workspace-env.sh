#!/usr/bin/env bash
# End-to-end shell/direnv setup using real Git worktrees and simulated Rails.
# Hosted Rails/PostgreSQL E2E separately tests actual ActiveRecord connections.
set -euo pipefail
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/gitwo-env.XXXXXXXX")"
trap 'rm -rf -- "$tmp"' EXIT
export HOME="$tmp/home" XDG_CONFIG_HOME="$tmp/home/.config"
mkdir -p "$HOME" "$tmp/work" "$tmp/prefix/bin" "$tmp/prefix/share/gitwo" "$tmp/tools" "$tmp/fake-ruby/bin"
cp -R "$here/." "$tmp/prefix/share/gitwo/"
cp "$here/../bin/gitwo" "$tmp/prefix/bin/gitwo"
chmod +x "$tmp/prefix/bin/gitwo"
export PATH="$tmp/tools:$tmp/prefix/bin:$PATH"
export GITWO_FAKE_RUBY_HOME="$tmp/fake-ruby"

# Fake only external process executables. Gitwo metadata, Git refs and port
# allocation remain real. Reject a DB target mismatch from native Rails.
cat > "$tmp/tools/mise" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
  where) printf '%s\n' "$GITWO_FAKE_RUBY_HOME" ;;
  exec) shift 2; [[ "$1" == -- ]]; shift; exec "$@" ;;
  *) exit 2 ;;
esac
SH
cat > "$tmp/tools/bundle" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == exec && "$2" == rails && "$3" == runner ]] || exit 2
[[ ! ${DATABASE_URL+x} && ! ${REDIS_URL+x} ]] || exit 3
if [[ ${RAILS_ENV:-development} == test ]]; then
  [[ "$GITWO_EXPECTED_DB" == "$GITWO_DB_TEST" ]] || exit 4
else
  [[ "$GITWO_EXPECTED_DB" == "$GITWO_DB_DEV" ]] || exit 5
fi
SH
chmod +x "$tmp/tools/mise" "$tmp/tools/bundle"

for name in alpha beta; do
  git init -q --bare "$tmp/work/$name-remote.git"
  git init -q -b main "$tmp/work/$name"
  git -C "$tmp/work/$name" config user.email ci@example.invalid
  git -C "$tmp/work/$name" config user.name 'Gitwo CI'
  mkdir -p "$tmp/work/$name/config" "$tmp/work/$name/db"
  printf "source 'https://rubygems.org'\ngem 'rails'\ngem 'pg'\n" > "$tmp/work/$name/Gemfile"
  printf '    rails (7.2.4)\n    pg (1.5.0)\n' > "$tmp/work/$name/Gemfile.lock"
  printf '# fixture\n' > "$tmp/work/$name/config/application.rb"
  cat > "$tmp/work/$name/config/database.yml" <<'YAML'
default: &default
  adapter: postgresql
development:
  <<: *default
  database: sample_development
test:
  <<: *default
  database: sample_test
production:
  <<: *default
  database: sample_production
YAML
  printf '# fixture\n' > "$tmp/work/$name/db/schema.rb"
  printf '3.3.14\n' > "$tmp/work/$name/.ruby-version"
  git -C "$tmp/work/$name" add .
  git -C "$tmp/work/$name" commit -qm initial
  git -C "$tmp/work/$name" remote add origin "$tmp/work/$name-remote.git"
  git -C "$tmp/work/$name" push -q -u origin main

  cd "$tmp/work/$name"
  gitwo init --yes >/dev/null
  cp config/database.yml "$tmp/original-$name-db"
  gitwo workspace env integrate --dry-run > "$tmp/$name-integration-preview"
  cmp config/database.yml "$tmp/original-$name-db"
  gitwo workspace env integrate --apply > "$tmp/$name-integration-apply"
  grep -Fq 'GITWO_DB_DEV' config/database.yml
  grep -Fq 'GITWO_DB_TEST' config/database.yml
  git add config/database.yml
  git commit -qm 'Enable Gitwo native database isolation'
  git push -q origin main
  path="$(gitwo workspace create develop --no-setup 2>/dev/null)"
  [[ "$path" == "$tmp/work/.gitwo-workspaces/$name/develop-1" ]]
  [[ -f "$path/.ruby-version" ]]
  (
    cd "$path"
    source "$here/_common.sh"
    gitwo_write_state "$path" develop DEVELOP-1
    printf '%s\n' "$GITWO_DB_DEV" > "$GITWO_STATE/develop-1.db-ready"
    printf 'ready\n' > "$GITWO_STATE/develop-1.bootstrap-status"
  )
  # verify must not allocate ports, start Redis, or create .envrc.
  count_before="$(find "$HOME/.local/state/gitwo/projects" -name 'develop-1.ports' -print | wc -l | tr -d ' ')"
  GITWO_HAS_REDIS=true gitwo workspace env verify "$path" > "$tmp/$name-verify-before.log" 2>&1 && { echo 'Expected verification to fail for missing ports' >&2; exit 1; }
  [[ ! -f "$path/.envrc" ]]
  count_after="$(find "$HOME/.local/state/gitwo/projects" -name 'develop-1.ports' -print | wc -l | tr -d ' ')"
  [[ "$count_before" == "$count_after" ]] || { echo 'verify unexpectedly allocated runtime ports' >&2; exit 1; }
  # A missing state must prevent activation. Only setup can record the marker.
  [[ -f "$path/.envrc" ]] && { echo 'Unexpected .envrc for --no-setup' >&2; exit 1; }
  gitwo workspace env init "$path" > "$tmp/$name-env.log" 2>&1
  [[ -f "$path/.envrc" && ! -L "$path/.envrc" ]]
  [[ -z "$(git -C "$path" status --porcelain --untracked-files=all)" ]]
  grep -qF 'source_env ' "$path/.envrc"
  grep -qF 'export GITWO_DIRENV_WORKSPACE=' "$path/.envrc"
  # Emulate source_env evaluating from the directory of its helper script.
  (
    cd "$tmp"
    export GITWO_DIRENV_WORKSPACE="$path"
    source "$here/direnv.sh"
    [[ "$GITWO_WORKSPACE" == develop-1 ]]
    [[ "$GITWO_DB_DEV" == "${name}_develop_1_development" ]]
    [[ "$PWD" == "$path" ]]
  )
  # direnv source_env sources ./direnv.sh from its own directory.
  (
    cd "$here"
    export GITWO_DIRENV_WORKSPACE="$path"
    source ./direnv.sh
    [[ "$GITWO_WORKSPACE" == develop-1 ]]
    [[ "$PWD" == "$path" ]]
  )
  grep -qxF '/.envrc' "$tmp/work/$name/.git/info/exclude"
  (
    cd "$path"
    export DATABASE_URL='postgresql://127.0.0.1/unsafe_development'
    export REDIS_URL='redis://127.0.0.1:6379/0'
    export RAILS_ENV=development
    export PAGER=less
    source "$here/direnv.sh"
    [[ "$GITWO_WORKSPACE" == develop-1 ]]
    [[ "$GITWO_DB_DEV" == "${name}_develop_1_development" ]]
    [[ "$GITWO_DB_TEST" == "${name}_develop_1_test" ]]
    [[ "$GITWO_DEV_DATABASE_URL" == *"$GITWO_DB_DEV" ]]
    [[ "$GITWO_TEST_DATABASE_URL" == *"$GITWO_DB_TEST" ]]
    [[ "$GITWO_DEV_REDIS_URL" == redis://127.0.0.1:* ]]
    [[ "$GITWO_TEST_REDIS_URL" == redis://127.0.0.1:* ]]
    [[ ! ${DATABASE_URL+x} && ! ${REDIS_URL+x} && ! ${RAILS_ENV+x} ]]
    [[ "$PAGER" == less ]]
    [[ "$APP_HOST" == localhost:* && "$PORT" =~ ^[0-9]{4,5}$ ]]
  )
  # No rewrite / no automatic trust if a file already exists.
  before="$(shasum -a 256 "$path/.envrc" 2>/dev/null || sha256sum "$path/.envrc")"
  gitwo workspace env init "$path" >/dev/null 2>&1
  after="$(shasum -a 256 "$path/.envrc" 2>/dev/null || sha256sum "$path/.envrc")"
  [[ "$before" == "$after" ]]
  ports_file="$(find "$HOME/.local/state/gitwo/projects" -name 'develop-1.ports' -print | tail -1)"
  ports_before="$(shasum -a 256 "$ports_file" 2>/dev/null || sha256sum "$ports_file")"
  GITWO_HAS_REDIS=true gitwo workspace env verify "$path" > "$tmp/$name-verify-after.log" 2>&1
  ports_after="$(shasum -a 256 "$ports_file" 2>/dev/null || sha256sum "$ports_file")"
  [[ "$ports_before" == "$ports_after" ]]

  if command -v direnv >/dev/null 2>&1; then
    direnv allow "$path" >/dev/null 2>&1
    direnv exec "$path" bash -c '[[ "$GITWO_WORKSPACE" == develop-1 && ! ${DATABASE_URL+x} ]]' >/dev/null
  fi
done

# Never overwrite a project-managed .envrc, even when it is untracked.
path="$tmp/work/.gitwo-workspaces/beta/develop-1"
printf '# Developer-owned direnv config\n' > "$path/.envrc"
gitwo workspace env init "$path" >"$tmp/ownership.log" 2>&1
[[ "$(cat "$path/.envrc")" == '# Developer-owned direnv config' ]]
grep -q 'refusing to overwrite' "$tmp/ownership.log"

printf '[PASS] workspace create aliases, independent direnv state, no dev/test DB mixing, existing .envrc safety\n'
