#!/usr/bin/env bash
# The distributable archive must install independently of the Git checkout.
set -euo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/gitwo-release-test.XXXXXXXX")"
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/out" "$tmp/extracted"
bash "$root/scripts/package-release.sh" "$tmp/out"
version="$(cat "$root/gitwo/VERSION")"
archive="gitwo-$version.tar.gz"
if command -v sha256sum >/dev/null 2>&1; then
  (cd "$tmp/out" && sha256sum -c "$archive.sha256")
else
  (cd "$tmp/out" && shasum -a 256 -c "$archive.sha256")
fi
tar -xzf "$tmp/out/$archive" -C "$tmp/extracted"
package="$tmp/extracted/gitwo-$version"
[[ -s "$package/SHA256SUMS" && -x "$package/bin/gitwo" ]]
bash "$package/install.sh" "$tmp/prefix" > "$tmp/install.log"
[[ "$("$tmp/prefix/bin/gitwo" --version)" == "gitwo $version" ]]
(cd "$tmp" && "$tmp/prefix/bin/gitwo" doctor) > "$tmp/doctor.log"
# A modified release archive must be refused by the verified installer.
printf '# tampered\n' >> "$package/gitwo/provider.rb"
if bash "$package/install.sh" "$tmp/other-prefix" > "$tmp/rejected.out" 2> "$tmp/rejected.err"; then
  echo 'Tampered extracted archive was installed' >&2
  exit 1
fi
grep -Fq 'checksum mismatch' "$tmp/rejected.err"
printf '[PASS] verified archive extraction, standalone install, doctor and tamper refusal\n'
