# Gitwo configuration scopes

Gitwo supports two adoption modes. **Local is the default for project initialization.**
Team mode is an explicit choice; testing Gitwo alone never requires a team commit.

## Local mode (default)

Run `gitwo init` or `gitwo init --scope=local` from an existing Rails checkout.
The wizard resolves the **primary Git worktree** (including when called inside a
linked worktree) and proposes its canonical path, then a private config file:

```text
Gitwo / init (scope: local)
Project checkout [/Users/dev/projects/rails-app]:
Configuration file [/Users/dev/.config/gitwo/projects/rails-app-4a3b...yml]:
```

Defaults appear in dim grey on ANSI terminals. Enter accepts the displayed
value, or type another path. `--project=PATH` and `--output=PATH` bypass the
corresponding prompts. Outside Git, you must select a valid existing checkout.

Local configs live in `$XDG_CONFIG_HOME/gitwo/projects/` or
`~/.config/gitwo/projects/` by default. Names include the canonical checkout
path's short SHA-256 digest, separating clones. If you choose a custom local
path, Gitwo saves an owner-only path reference under XDG. It is resolved
automatically later, without exporting `GITWO_CONFIG_FILE`.

**Safety:** local YAML must be outside every Git checkout; init never writes
tracked Rails files, project `gitwo.yml`, secrets, or Git commits. Gitwo uses
existing Git repositories, not `git init`. Explicitly creating a workspace
still creates local branches and worktree metadata.

```sh
gitwo init --scope=local
gitwo onboard --scope=local
gitwo new feature improve-search  # Full isolated Rails setup, no issue key
gitwo config path
```

For automatic Rails setup, the app must already support Gitwo development
and test DB isolation. Local init never silently patches `config/database.yml`.
To experiment without changing project files, use `--no-setup` initially.

## Team mode

```sh
gitwo init --scope=team
git status --short
# Commit the reviewed gitwo.yml only if your team chooses to adopt Gitwo.
gitwo onboard --scope=team
gitwo onboard --scope=team --check --json
```

Team init writes only the new, untracked project-root `gitwo.yml`.
It never runs `git add`, `git commit`, or `git push`. Existing files are not
overwritten. CI checks require the team YAML to be committed and tracked.
Credentials remain private on each developer's machine.

## Selecting and switching

```sh
gitwo config use local
gitwo config use team
gitwo config path
gitwo config scope
```

Both configs can coexist. Selected scope is stored in an owner-only XDG
metadata file, outside the repo. Switching never copies personal YAML into
the team file. Existing team repositories remain compatible until a scope is
chosen explicitly. `GITWO_SCOPE=team` or explicit `GITWO_CONFIG_FILE` can
override the stored selection for an individual process.

## Noninteractive use

```sh
gitwo init --scope=local --project="$PWD" --yes
gitwo init --scope=team --project="$PWD" --yes
gitwo init --scope=local --dry-run --json
gitwo onboard --scope=local --check --json
gitwo onboard --scope=team --check --json
```

Dry-run and JSON initialization never write files. An interactive init
requires a final confirmation. No paths are selected through AI or
unverified guesses about adjacent projects.
