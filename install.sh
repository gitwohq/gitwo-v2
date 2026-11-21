#!/usr/bin/env bash
# Standalone, checksum-verified installation under ~/.local. Does not touch project state.
set -euo pipefail
package="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
prefix="${1:-${GITWO_INSTALL_PREFIX:-$HOME/.local}}"
[[ "$prefix" == /* ]] || { printf 'ERROR: Installation prefix must be absolute\n' >&2; exit 2; }
[[ -f "$package/SHA256SUMS" && ! -L "$package/SHA256SUMS" ]] || { echo 'ERROR: Missing SHA256SUMS' >&2; exit 1; }
if command -v sha256sum >/dev/null; then
  (cd "$package" && sha256sum -c SHA256SUMS >/dev/null) || { echo 'ERROR: Package checksum mismatch' >&2; exit 1; }
elif command -v shasum >/dev/null; then
  (cd "$package" && shasum -a 256 -c SHA256SUMS >/dev/null) || { echo 'ERROR: Package checksum mismatch' >&2; exit 1; }
else
  echo 'ERROR: Install sha256sum or shasum before proceeding' >&2
  exit 1
fi
for path in gitwo/_common.sh gitwo/provider.rb gitwo/onboard.rb gitwo/shell.zsh bin/gitwo; do
  [[ -s "$package/$path" && ! -L "$package/$path" ]] || { echo "ERROR: Missing $path" >&2; exit 1; }
done
mkdir -p "$prefix/share" "$prefix/bin"
[[ ! -L "$prefix/share/gitwo" && ! -L "$prefix/bin/gitwo" ]] || { echo 'ERROR: Refusing symlinked install destination' >&2; exit 1; }
if [[ -e "$prefix/bin/gitwo" && ! -f "$prefix/bin/gitwo" ]]; then
  echo 'ERROR: Refusing nonregular bin/gitwo'; exit 1
fi
stage="$(mktemp -d "$prefix/share/.gitwo-install.XXXXXXXX")"
trap 'rm -rf -- "$stage"' EXIT
cp -R "$package/gitwo/." "$stage/"
cp -R "$package/bin" "$stage/launcher"
chmod +x "$stage"/*.sh "$stage/launcher/gitwo"
"$stage/doctor.sh" >/dev/null
stamp="$(date +%Y%m%d-%H%M%S)-$$"
if [[ -d "$prefix/share/gitwo" ]]; then
  backup="$prefix/share/gitwo.backup-$stamp"
  [[ ! -e "$backup" ]] || { echo "ERROR: Backup already exists: $backup" >&2; exit 1; }
  mv "$prefix/share/gitwo" "$backup"
  printf '[OK] Previous installation backup: %s\n' "$backup"
fi
# The launcher lives at prefix/bin and reads installed shared scripts from prefix/share.
launcher_stage="$(mktemp "$prefix/bin/.gitwo.XXXXXXXX")"
trap 'rm -rf -- "$stage"; rm -f -- "$launcher_stage"' EXIT
cp "$stage/launcher/gitwo" "$launcher_stage"
rm -rf -- "$stage/launcher"
chmod 755 "$launcher_stage"
if [[ -f "$prefix/bin/gitwo" ]]; then
  mv "$prefix/bin/gitwo" "$prefix/bin/gitwo.backup-$stamp"
fi
mv "$stage" "$prefix/share/gitwo"
# Release payload includes a launcher directory, harmless within share/gitwo.
mv "$launcher_stage" "$prefix/bin/gitwo"
"$prefix/bin/gitwo" --version
printf '[OK] Installed: %s/bin/gitwo\n' "$prefix"
printf '[INFO] Shell integration: source "%s/share/gitwo/shell.zsh"\n' "$prefix"
printf '[INFO] Open a Git checkout and run: gitwo init\n'
