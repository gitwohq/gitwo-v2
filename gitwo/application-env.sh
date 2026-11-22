#!/usr/bin/env bash
# Preserve the application's existing local environment conventions.
# No .env parsing, secret inspection, generated templates, or Rails file edits.
# Sourced by setup.sh after verifying the selected Gitwo worktree.
#
# Git already carries tracked files into a worktree. Only copy a small,
# development/test-specific allowlist including ignored database.yml of ignored files from the main checkout.
# Deliberately exclude staging and production secrets.

gitwo_application_env_copy_ignored() {
  local source_root="$1" target_root="$2" file original target parent

  for file in \
    .env .env.local .env.development .env.development.local \
    .env.test .env.test.local .envrc \
    config/database.yml config/master.key config/credentials/development.key config/credentials/test.key; do
    original="$source_root/$file"
    target="$target_root/$file"

    if [[ -L "$original" ]]; then
      gitwo_warn "Not copying symlinked application environment file: $file"
      continue
    fi
    [[ -f "$original" ]] || continue

    # Tracked files already exist in the worktree. Never duplicate or modify.
    if git -C "$source_root" ls-files --error-unmatch -- "$file" >/dev/null 2>&1; then
      continue
    fi
    if ! git -C "$source_root" check-ignore -q -- "$file"; then
      gitwo_warn "Not copying untracked, non-ignored application file: $file"
      continue
    fi
    if [[ -L "$target" ]]; then
      gitwo_warn "Existing symlinked application environment file left untouched: $file"
      continue
    fi
    [[ ! -e "$target" ]] || continue

    # Do not follow symlinked parent directories when placing credentials.
    if [[ "$file" == config/* ]]; then
      [[ ! -L "$target_root/config" ]] ||
        gitwo_die 'Refusing application ENV copy through symlinked config directory'
      if [[ "$file" == config/credentials/* ]]; then
        [[ ! -L "$target_root/config/credentials" ]] ||
          gitwo_die 'Refusing application ENV copy through symlinked credentials directory'
      fi
    fi
    parent="$(dirname "$target")"
    mkdir -p "$parent"
    # Exclusive-create with owner-only permissions. Never clobber a local file.
    (umask 077; set -C; cat "$original" > "$target") ||
      gitwo_die "Could not safely copy application environment file: $file"
    chmod 600 "$target"
    gitwo_ok "Preserved ignored application environment file: $file"
  done
}
