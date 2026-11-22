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
- Hosted CI has passed Rails/PostgreSQL/Redis on Ubuntu and Rails/Portless HTTPS on macOS using synthetic fixtures.
- Existing legacy project-specific setup must stay on its previous local Gitwo version until migrated and verified.
- Source checkout must remain on its configured branch. No automatic mutation of that branch.

Release hardening (2026-11-21): MIT license, strict data parsing for state and ports, verified TLS health checks, and macOS Portless HTTPS E2E workflow. See docs/release-security-review.md.

Release CI hardening: consolidated SHA-pinned workflow, fail-fast dependency policy,
Rails fixture updated to 7.2.4, no duplicate PR branch runs, and dependency inventory.


Release-readiness changes (2026-11-22):
- Extended real Rails E2E coverage to pinned Rails 8.1.4.1 and rspec-rails 8.1.0 on native and isolated Compose backends.
- Added concurrent allocation regression with five workspaces and safer Compose removal preflight.
- Hardened runtime port metadata validation, and improved doctor checks for Docker, direnv and Portless.
- Added a source archive builder plus Linux/macOS installation-from-archive tests.
- Pre-release distribution instructions: `bash scripts/package-release.sh "$PWD/dist"` and `bash tests/test-release-package.sh`.
- The generated `gitwo-4.21.0.tar.gz` and `.sha256` are **local release candidates**, not published GitHub Releases.
- Before a public release, complete the [macOS acceptance checklist](docs/macos-acceptance.md) on a real trusted Rails project.


Team onboarding milestone (2026-11-22): `gitwo onboard` validates committed
`gitwo.yml`, checks developer dependencies without editing the repository,
and offers an explicitly confirmed `--setup` for schema-only workspaces.
`gitwo onboard --check --json` is safe for CI. Clone folder names may differ
from the shared `project.source` label. See docs/team-onboarding.md.
