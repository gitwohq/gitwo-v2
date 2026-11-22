#!/usr/bin/env bash
# Build a source-only release archive from a committed, checksum-verified tree.
# This command does not create a GitHub Release or change any installed Gitwo.
set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
version="$(cat "$root/gitwo/VERSION")"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Invalid Gitwo version' >&2; exit 2; }
output="${1:-$root/dist}"
[[ "$output" == /* ]] || { echo 'Output directory must be absolute' >&2; exit 2; }
git -C "$root" rev-parse --verify HEAD >/dev/null
if ! git -C "$root" diff --quiet HEAD -- || ! git -C "$root" diff --cached --quiet; then
  echo 'Commit tracked changes before packaging a release' >&2
  exit 1
fi
mkdir -p "$output"
archive="gitwo-$version.tar.gz"
[[ ! -e "$output/$archive" && ! -L "$output/$archive" ]] || {
  echo "Release artifact already exists: $output/$archive" >&2
  exit 1
}
tmp="$(mktemp -d "${TMPDIR:-/tmp}/gitwo-package.XXXXXXXX")"
trap 'rm -rf -- "$tmp"' EXIT

# git archive includes only tracked files and preserves executable modes.
git -C "$root" archive --format=tar --prefix="gitwo-$version/" HEAD | gzip -n > "$tmp/$archive"
tar -tzf "$tmp/$archive" | grep -Fx "gitwo-$version/SHA256SUMS" > /dev/null
if command -v sha256sum >/dev/null 2>&1; then
  checksum="$(sha256sum "$tmp/$archive" | awk '{print $1}')"
else
  checksum="$(shasum -a 256 "$tmp/$archive" | awk '{print $1}')"
fi
printf '%s  %s\n' "$checksum" "$archive" > "$tmp/$archive.sha256"
mv "$tmp/$archive" "$output/$archive"
mv "$tmp/$archive.sha256" "$output/$archive.sha256"
printf '[OK] Release candidate: %s/%s\n' "$output" "$archive"
printf '[INFO] Archive SHA-256: %s\n' "$checksum"
