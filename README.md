# Gitwo

Gitwo is a Bash/Ruby CLI for isolated local development environments using Git worktrees.
The current pre-release focuses on Rails, PostgreSQL, Redis and optional Portless HTTPS.
It supports Jira, Linear, GitHub Issues, or no issue tracker.

## Install (development snapshot)

```sh
bash install.sh
export PATH="$HOME/.local/bin:$PATH"
source "$HOME/.local/share/gitwo/shell.zsh"
gitwo --version
```

From a trusted Rails checkout:

```sh
gitwo detect
gitwo init --dry-run
gitwo init
gitwo new develop --no-setup
gitwo list --json
```

Full Rails setup uses local PostgreSQL, Ruby/Bundler, mise and, when configured,
Redis and Portless. `gitwo doctor --deps` checks the local prerequisites.

## Everyday workflow

```sh
gitwo new feature ENG-123
gitwo up
gitwo run test  # Auto-detects Minitest or RSpec
gitwo status
gitwo logs
gitwo down
gitwo remove --dry-run
```

Do not run unknown project code or Rails seeds outside a trusted checkout.
Existing legacy project installations and PostgreSQL databases are not migrated.

## Development and CI

```sh
bash tests/check-dependencies.sh
bash gitwo/test-all.sh
bash test-installer.sh
```

[Gitwo CI](.github/workflows/ci.yml) runs checks in ascending resource-cost order:
static/dependency audit, Linux regression, macOS regression, Linux Rails E2E,
and macOS Rails+Portless HTTPS E2E. The Linux E2E overlaps the lightweight
macOS regression to reduce overall time; the expensive macOS HTTPS job is gated
by both. All GitHub Actions are full-commit-SHA pinned.

Both Ubuntu Rails/PostgreSQL/Redis and macOS Portless HTTPS fixtures passed in
GitHub Actions on 2026-11-21. The tests use synthetic data, not private code.
The project is still pre-release until the release artifact is tested.

Read the [dependency inventory](docs/dependencies.md),
[security policy](SECURITY.md), [security review](docs/release-security-review.md),
and [release notes](README-RELEASE.md). License: [MIT](LICENSE).
