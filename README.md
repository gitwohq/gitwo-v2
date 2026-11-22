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
gitwo init --scope=local --dry-run
gitwo init                      # Local scope is default; no project files modified
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

## Service backends

Use `gitwo detect --json` to inspect application Compose file presence. `gitwo init`
lets you choose `services.backend: native` (default) or `compose`. Native runs
local PostgreSQL/Redis processes. Compose creates a **separate Gitwo-owned**
Compose project for each workspace (PostgreSQL 16 and two Redis 7 containers).
No application Compose file is executed or overwritten. PostgreSQL uses a named
volume, and `gitwo services down` preserves it. Exposed ports bind only to loopback.
Docker Compose V2 is required only for the Compose backend. The host Rails process
still needs environment-specific DB/Redis configuration; Compose alone does not
choose development versus test.

`gitwo services up|status|down [WORKSPACE]` manages the selected workspace.
For native Rails HTTPS: `gitwo workspace proxy register [WORKSPACE]`, then run
`bin/rails server`; `gitwo workspace proxy unregister` removes only the owned alias.

## Workspace activation

Prefer `gitwo workspace create feature ENG-123`. With [direnv](https://direnv.net/)
installed and allowed for the generated untracked `.envrc`, native Rails,
RSpec and Minitest commands work in the selected worktree without `gitwo run`.
Gitwo verifies separate development and test database configurations before
creating the activation file. Conventional Rails configurations can be prepared
with `gitwo workspace env integrate --dry-run` and explicitly updated with
`--apply` after review. The `verify` command does not allocate ports or start Redis.
See [workspace activation](docs/workspace-activation.md).

## Release candidate preparation

The CLI is pre-release. CI tests synthetic Rails 7.2.4 and Rails 8.1.4.1
applications with native PostgreSQL/Redis and managed Compose backends.
The release builder creates a source-only archive and SHA-256 sidecar from the
committed tree without publishing a GitHub Release:

```sh
bash scripts/package-release.sh "$PWD/dist"
bash tests/test-release-package.sh
```

The archive is installed and tamper-tested on both Linux and macOS in CI.
See [macOS acceptance](docs/macos-acceptance.md) before trying Gitwo against
private project data. A release still requires successful real-device acceptance.

## Local and team configuration scopes

Use `gitwo init` for an individual experiment. It stores a private config under
`~/.config/gitwo/projects/` and never writes into the Rails repository.
Use `gitwo init --scope=team` only when your team opts into a shared file.

Commit a reviewed `gitwo.yml` to the Rails repository once. Every teammate
can then clone it under their preferred local directory name and reuse the
same configuration without running `gitwo init` again:

```sh
gitwo onboard --scope=team               # Check shared config and local dependencies
gitwo onboard --scope=team --check       # CI-safe, read-only team contract
gitwo onboard --scope=team --check --json
gitwo onboard --scope=team --setup       # Explicitly create develop-N without seeds
```

Only `--setup` starts the normal Gitwo worktree/DB initialization path, after
confirmation. Credentials, runtime state and generated `.envrc` remain local.
See [team onboarding](docs/team-onboarding.md) and [scope selection](docs/configuration-scopes.md).
