# Team onboarding

Gitwo has two distinct phases:

- A **maintainer** configures the Rails repository once with `gitwo init`,
  reviews the generated `gitwo.yml` and commits it together with any reviewed
  `config/database.yml` integration. No API tokens or passwords belong in Git.
- Each **developer** installs the Gitwo CLI on their own machine, clones the
  repository, and runs `gitwo onboard`. The shared YAML is reused, not
  regenerated. The local clone directory can have any safe name.

```sh
git clone git@github.com:company/rails-app.git my-rails-project
cd my-rails-project
gitwo onboard
```

This command validates the checked-in `gitwo.yml` and reports the missing
local tools for the configured native or Compose backend, proxy and issue
provider. It does not install software, contact external issue trackers,
start containers, create databases, read secret values or edit tracked files.
For a configured Jira/Linear provider it checks only the presence and safe
permissions of private credentials. The team can share a nonsecret credential
**profile name** in YAML without sharing the actual token.

When dependencies are ready, create a workspace with normal Gitwo commands:

```sh
gitwo new develop --no-seed
```

For an explicit one-command bootstrap, after reviewing the tracked Rails
database configuration:

```sh
gitwo onboard --setup
```

`--setup` asks for confirmation (type `setup`) before delegating to Gitwo's
normal workspace creation path. For a trusted noninteractive environment use
`gitwo onboard --setup --yes` deliberately. Both use schema-only DB
bootstrap and `--no-seed`; a failed partial setup is left intact for inspection.
A conventional `config/database.yml` must already include `GITWO_DB_DEV`
and `GITWO_DB_TEST`. Preview the opt-in integration using
`gitwo workspace env integrate --dry-run`. Review changes and commit
them before enabling team onboarding. The actual DB isolation is verified
again by the workspace setup process.

## CI and machine-specific diagnostics

```sh
gitwo onboard --check
gitwo onboard --check --json
gitwo onboard --check --local
```

`--check` is a **read-only config contract**: it requires `gitwo.yml`
to be present in `HEAD` and pass Gitwo's strict YAML schema checks. It
does not depend on Docker, PostgreSQL, credentials or system services and
is suitable for pull-request CI. Use `--check --local` for a developer
machine diagnostic; it checks installed tools without modifying them.

`--json` returns a status and list of structured checks without secrets.
The command exits nonzero on a failed required check; warnings (such as
missing optional provider authentication) do not fail CI.

## What stays local

The canonical checkout path identifies local project state, including
`~/.local/state/gitwo/projects/<project-id>` and all `develop-N` worktrees.
Private Jira/Linear credentials are stored outside the repository under
`~/.config/gitwo/credentials/<profile>/`, or passed in the developer's process
environment. Generated workspace `.envrc` files are untracked and require
explicit `direnv allow`. No `.env` containing actual credentials is
generated or committed by onboarding.

The `project.source` field is a logical shared label, **not** a required
local checkout directory basename. The local path still determines the
workspace directory and state identity.

## Boundaries

Gitwo does not install Homebrew, Docker Desktop, Node, Ruby or database
packages automatically and will not edit an application's `.env` or
`.env.example`. Keep those templates application-owned. Provider authentication
may need a separate `gh auth login` or private credential-file setup.
A successful `--check` proves config portability, not that local Rails,
PostgreSQL, Redis or HTTPS can actually boot. Use the
[macOS acceptance checklist](macos-acceptance.md) for on-device smoke tests.
