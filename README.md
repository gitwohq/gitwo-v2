# Gitwo

Gitwo manages isolated local development environments backed by Git worktrees.

The current implementation is a Bash/Ruby prototype focused on Rails and PostgreSQL.
This repository is the universal, project-agnostic successor to earlier local scripts.
It does not migrate or modify existing per-project installations.

## Requirements

Git, Bash, Ruby 3.3, and (for full Rails workflows) PostgreSQL, Redis and Rails.
Portless is optional.

## Install

```sh
bash install.sh
export PATH="$HOME/.local/bin:$PATH"
source "$HOME/.local/share/gitwo/shell.zsh"
gitwo --version
```

The installer verifies `SHA256SUMS` and creates a backup before replacing a prior installation.

## Initialize a project

From a Rails checkout:

```sh
gitwo detect
gitwo init --dry-run
gitwo init
gitwo new develop --no-setup
gitwo list --json
```

Gitwo uses auto-detection and lets you review Git workflow, issue tracker and
runtime settings. `gitwo init --yes` is available for noninteractive setup.
Issue providers: Jira, Linear, GitHub Issues, or none.

## Everyday commands

```sh
gitwo new feature ENG-123 --no-setup
gitwo up
gitwo status
gitwo logs
gitwo down
gitwo remove --dry-run
```

For complete help run `gitwo --help` or `gitwo help new`.

## State and safety

New projects store workspaces separately from the main Git checkout.
Per-project runtime metadata is under `~/.local/state/gitwo/projects/`.
Credentials are stored separately from committed `gitwo.yml`.
An existing per-project installation is not migrated automatically.

Database replacement and worktree removal require explicit confirmation.
Inspect commands and dry-run modes before destructive operations.

## Development and CI

```sh
bash gitwo/test-all.sh
bash test-installer.sh
```

GitHub Actions runs smoke and provider tests on Ubuntu and macOS.
A real Rails/PostgreSQL/Redis E2E suite is planned separately; until it passes,
the project should be considered pre-release.

See [release notes](README-RELEASE.md) and [Gitwo docs](gitwo/README.md).
