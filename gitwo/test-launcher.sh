#!/usr/bin/env bash
# The launcher selection and execution contract never needs PostgreSQL or Rails.
set -euo pipefail
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/gitwo-launcher.XXXXXXXX")"
trap 'rm -rf -- "$tmp"' EXIT
source "$here/_launcher.sh"
mkdir -p "$tmp/app/bin" "$tmp/tools"
[[ "$(gitwo_launcher_detect "$tmp/app")" == rails ]]

cat > "$tmp/app/bin/dev" <<'SH'
#!/usr/bin/env bash
printf 'bin-dev PORT=%s APP_HOST=%s DATABASE_URL=%s\n' "${PORT:-}" "${APP_HOST:-}" "${DATABASE_URL:-}"
SH
chmod +x "$tmp/app/bin/dev"
[[ "$(gitwo_launcher_detect "$tmp/app")" == bin-dev ]]
[[ "$(gitwo_launcher_detect "$tmp/app" rails)" == rails ]]
[[ "$(gitwo_launcher_detect "$tmp/app" bin-dev)" == bin-dev ]]

# A Procfile is deliberately inert during detection. This test would fail if
# a shell evaluated it, as it contains a malicious command substitution.
rm "$tmp/app/bin/dev"
cat > "$tmp/app/Procfile.dev" <<'PROC'
web: bundle exec rails s
worker: echo $(touch /should-not-exist)
PROC
if gitwo_launcher_detect "$tmp/app" bin-dev > "$tmp/missing" 2>&1; then
  echo 'Explicit bin-dev unexpectedly succeeded without bin/dev' >&2; exit 1
fi
if gitwo_launcher_detect "$tmp/app" not-a-launcher > "$tmp/unknown" 2>&1; then
  echo 'Unexpected launcher override accepted' >&2; exit 1
fi
[[ ! -e /should-not-exist ]]
cat > "$tmp/tools/foreman" <<'SH'
#!/usr/bin/env bash
printf 'foreman PORT=%s APP_HOST=%s DATABASE_URL=%s argv=%s\n' "${PORT:-}" "${APP_HOST:-}" "${DATABASE_URL:-}" "$*"
SH
cat > "$tmp/tools/overmind" <<'SH'
#!/usr/bin/env bash
printf 'overmind PORT=%s APP_HOST=%s DATABASE_URL=%s argv=%s\n' "${PORT:-}" "${APP_HOST:-}" "${DATABASE_URL:-}" "$*"
SH
chmod +x "$tmp/tools/"*
export PATH="$tmp/tools:$PATH"
[[ "$(gitwo_launcher_detect "$tmp/app")" == overmind ]]
[[ "$(gitwo_launcher_detect "$tmp/app" foreman)" == foreman ]]
[[ "$(gitwo_launcher_detect "$tmp/app" overmind)" == overmind ]]

# The selected process manager receives the already assigned web PORT and
# Rails/database context after Portless or the direct launcher starts it.
(
  cd "$tmp/app"
  PORT=12345 APP_HOST=feature.localhost DATABASE_URL=postgresql://localhost/workspace \
    bash "$here/_launcher.sh" exec foreman --trace > "$tmp/foreman.out"
  PORT=12346 APP_HOST=feature.localhost DATABASE_URL=postgresql://localhost/workspace \
    bash "$here/_launcher.sh" exec overmind --verbose > "$tmp/overmind.out"
)
grep -Fq 'foreman PORT=12345 APP_HOST=feature.localhost DATABASE_URL=postgresql://localhost/workspace argv=start -f Procfile.dev -p 12345 --trace' "$tmp/foreman.out"
grep -Fq 'overmind PORT=12346 APP_HOST=feature.localhost DATABASE_URL=postgresql://localhost/workspace argv=start -f Procfile.dev -p 12346 --verbose' "$tmp/overmind.out"

cat > "$tmp/tools/bundle" <<'SH'
#!/usr/bin/env bash
printf 'bundle PORT=%s APP_HOST=%s DATABASE_URL=%s argv=%s\n' "${PORT:-}" "${APP_HOST:-}" "${DATABASE_URL:-}" "$*"
SH
chmod +x "$tmp/tools/bundle"
(
  cd "$tmp/app"
  PORT=12001 APP_HOST=localhost:12001 DATABASE_URL=postgresql://localhost/workspace \
    bash "$here/_launcher.sh" exec rails > "$tmp/rails.out"
)
grep -Fq 'bundle PORT=12001 APP_HOST=localhost:12001 DATABASE_URL=postgresql://localhost/workspace argv=exec rails server -b 127.0.0.1' "$tmp/rails.out"

cat > "$tmp/app/bin/dev" <<'SH'
#!/usr/bin/env bash
printf 'bin-dev PORT=%s APP_HOST=%s DATABASE_URL=%s\n' "${PORT:-}" "${APP_HOST:-}" "${DATABASE_URL:-}"
SH
chmod +x "$tmp/app/bin/dev"
(
  cd "$tmp/app"
  PORT=12400 APP_HOST=localhost:12400 DATABASE_URL=postgresql://localhost/workspace \
    bash "$here/_launcher.sh" exec bin-dev > "$tmp/dev.out"
)
grep -Fq 'bin-dev PORT=12400 APP_HOST=localhost:12400 DATABASE_URL=postgresql://localhost/workspace' "$tmp/dev.out"

rm "$tmp/app/bin/dev"
printf 'worker: bundle exec sidekiq\n' > "$tmp/app/Procfile.dev"
if gitwo_launcher_detect "$tmp/app" overmind > "$tmp/no-web" 2>&1; then
  echo 'Process manager accepted a Procfile without a web process' >&2; exit 1
fi
grep -Fq 'no web process' "$tmp/no-web"
cat > "$tmp/app/Procfile.dev" <<'PROC'
worker: bundle exec sidekiq
web: bin/rails server -p "$PORT"
PROC
if gitwo_launcher_detect "$tmp/app" foreman > "$tmp/web-second" 2>&1; then
  echo 'Process manager accepted web as the second port' >&2; exit 1
fi
grep -Fq 'must list web first' "$tmp/web-second"
printf 'web: bin/rails server\n' > "$tmp/app/Procfile.dev"
ln -s /tmp/nonexistent "$tmp/app/bin/dev"
if gitwo_launcher_detect "$tmp/app" > "$tmp/unsafe" 2>&1; then
  echo 'Symlinked bin/dev unexpectedly accepted' >&2; exit 1
fi
grep -Fq 'symlinked development launcher' "$tmp/unsafe"

printf '[PASS] runtime launcher: discovery, safe refusal, Rails/Foreman/Overmind/bin-dev context forwarding\n'
