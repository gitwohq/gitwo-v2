#!/usr/bin/env bash
# Test complete package installation and checksum refusal in an ephemeral prefix.
set -euo pipefail
package="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/gitwo-installer.XXXXXXXX")"
trap 'rm -rf -- "$tmp"' EXIT
export HOME="$tmp/home"
mkdir -p "$HOME" "$tmp/prefix"
bash "$package/install.sh" "$tmp/prefix" > "$tmp/install.log"
[[ -x "$tmp/prefix/bin/gitwo" ]]
[[ "$("$tmp/prefix/bin/gitwo" --version)" == 'gitwo 4.21.0' ]]
(cd "$tmp" && "$tmp/prefix/bin/gitwo" doctor) > "$tmp/doctor.log"
grep -q 'components present' "$tmp/doctor.log"
# Per-project legacy installation is left untouched by the global installer.
mkdir -p "$tmp/legacy/gitwo/.state"
printf 'sentinel\n' > "$tmp/legacy/gitwo/.state/important"
bash "$package/install.sh" "$tmp/prefix" > "$tmp/reinstall.log"
[[ "$(cat "$tmp/legacy/gitwo/.state/important")" == sentinel ]]
ls "$tmp/prefix/share"/gitwo.backup-* >/dev/null
# A modified package is rejected before it can alter the previous install.
cp -R "$package" "$tmp/damaged"
printf '# tamper\n' >> "$tmp/damaged/gitwo/provider.rb"
if bash "$tmp/damaged/install.sh" "$tmp/prefix" > "$tmp/rejected.stdout" 2> "$tmp/rejected.stderr"; then
  echo 'Tampered package must be rejected' >&2
  exit 1
fi
grep -q 'checksum mismatch' "$tmp/rejected.stderr"
[[ "$("$tmp/prefix/bin/gitwo" --version)" == 'gitwo 4.21.0' ]]
printf '[PASS] global installation, upgrade backup, unchanged legacy state, SHA-256 rejection\n'
