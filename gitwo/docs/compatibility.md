# Migration from per-project installations

Gitwo 4.21 uses a standalone executable and a different state/workspace layout. Do not run its `remove`, `clean` or `setup --rebuild-db` on worktrees managed by an older installation.

1. Leave your old installation, `.state`, existing worktrees, DBs and credentials untouched.
2. Install this package globally using `install.sh`.
3. Initialize a NEW synthetic project or repo with `gitwo init --yes`.
4. Verify issue lookup, `gitwo new --no-setup`, distinct project state and safe `down`.
5. Plan an explicit, backed-up migration of old worktrees later; automated legacy state migration is not implemented.

Do not manually copy old `.state` into the new per-project directory. Metadata could refer to a different database or hostname.
