# Gitwo 4.21.0 - Multi-project foundation and issue providers

This package is a NEW, standalone installation under ~/.local/bin and ~/.local/share/gitwo.
It does NOT overwrite older per-project installations or migrate their .state / PostgreSQL databases.

Highlights:
- `gitwo init` discovers Rails/git branch strategy and writes `gitwo.yml` to the primary repository.
- `gitwo new` uses `issues.provider: jira | linear | github | none`.
- GitHub Issues lookup via authenticated `gh api`. Linear via read-only GraphQL issue query.
- Per-project worktree directories: `<repo-parent>/.gitwo-workspaces/<repo-name>/`.
- Per-project persistent state: `~/.local/state/gitwo/projects/<sha256(primary checkout realpath)[0..15]>`.
- Private credentials under `~/.config/gitwo` (0600) or process ENV. No secrets in gitwo.yml.
- `gitwo detect` works read-only. `gitwo doctor` checks new installation.

Safety:
- Worktrees and databases are not migrated automatically from old installations.
- `gitwo init --yes` uses schema-only bootstrap until user explicitly elects seeds.
- `gitwo new ... --no-setup` is useful to validate provider naming and isolation without databases.
- Standard Rails adapter currently supports PostgreSQL + Ruby/Rails. Other frameworks not supported.

Known limitations:
- Real external provider API calls need connected accounts/credentials and have not been exercised against a private project.
- An experimental Linux E2E job now exercises Rails, PostgreSQL, Redis and direct-mode Puma; its results must be verified on GitHub Actions. Portless HTTPS remains out of scope for this E2E job.
- Existing legacy project-specific setup must stay on its previous local Gitwo version until migrated and verified.
- Source checkout must remain on its configured branch. No automatic mutation of that branch.

Release hardening (2026-11-21): MIT license, strict data parsing for state and ports, verified TLS health checks, and macOS Portless HTTPS E2E. See docs/release-security-review.md.
