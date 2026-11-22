# Existing application environment files

Gitwo creates isolated Rails workspaces. It does **not** introduce an application
ENV convention, reformat a team's dotfiles, or require an external secret manager.

Application ENV belongs to the application. Gitwo's computed workspace variables
belong to Gitwo. These responsibilities stay separate.

## What is preserved

Tracked application files are already present in every Git worktree. During
Rails setup, `gitwo/application-env.sh` also copies the following **ignored**
local files from the primary checkout if they exist:

| Existing file | Treatment |
|---|---|
| `.env`, `.env.local` | Preserve without parsing or rewriting |
| `.env.development`, `.env.development.local` | Preserve without renaming |
| `.env.test`, `.env.test.local` | Preserve without renaming |
| `.envrc` | Preserve the application's own direnv rules |
| `config/master.key` | Preserve only when ignored and a regular file |
| `config/credentials/development.key`, `config/credentials/test.key` | Preserve only when ignored and regular |

No additional application ENV files are generated. The module copies only
regular files, with owner-only permissions and exclusive creation. It never
overwrites existing files, follows symlinked sources or destination paths, or
copies staging/production ENV or credential files. An untracked local file that
is **not ignored** is left untouched and reported, rather than silently
creating new untracked files in worktrees.

The module does not read or print secret values. Rails/dotenv/direnv loading
order remains the application's responsibility, exactly as before.

## Existing .envrc

When an application already has a tracked or ignored `.envrc`, Gitwo does not
replace or append to it. In that case `gitwo new` does not generate its own
activation file. The application can continue using its existing direnv rules.

**Do not assume direct `bin/rails` commands are database-isolated** just because
the application's `.envrc` exists. Use `gitwo run WORKSPACE rails ...` or
`gitwo run WORKSPACE test`, which explicitly select the isolated workspace
database. Native activation can be verified separately with
`gitwo workspace env verify WORKSPACE`; no change to tracked
`database.yml` is required for the Gitwo-wrapped commands.

When the application has **no** `.envrc`, Gitwo retains its existing optional
native activation behavior: verify the effective development/test targets
before generating an ignored local `.envrc`. It never overwrites a file or
automatically approves direnv.

## Scope and service backends

Personal/team `gitwo.yml` is optional for local workspaces; it controls Gitwo
settings, not application dotenv files. Team adoption does not change this
copying contract.

Managed Compose is Gitwo-owned and isolated. Existing application
`compose.yaml` and `env_file` declarations are not evaluated or modified.
A project's existing external secret store is likewise not required or
configured by Gitwo.

Rails setup continues to initialize dedicated development/test PostgreSQL
databases and verifies their targets before mutation. This preservation step
is not a guarantee that arbitrary application initializers, API clients,
background jobs or custom multi-database configurations have no side effects;
review those in the application before running trusted code.
