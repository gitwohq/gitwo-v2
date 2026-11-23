# Native Rails development in a Gitwo workspace

Gitwo owns workspace creation, setup and resource lifecycle. `direnv` owns the
per-directory shell environment. Rails, Minitest, RSpec and Sidekiq still use
their standard commands.

## 1. Configure Rails database isolation once

Rails sees the same `DATABASE_URL` in development and test if it is exported for
the whole directory. Exporting a development URL unconditionally is unsafe:
`bin/rails test` or `bundle exec rspec` could use or reset the development DB.

For a conventional PostgreSQL `config/database.yml`, Gitwo can preview a
**one-time, explicit, reviewable** integration. From the primary Rails checkout:

```sh
gitwo workspace env integrate --dry-run
# Preview only; no files, ports or services change.

gitwo workspace env integrate --apply
# Explicitly updates only development/test `database:` entries.
git diff -- config/database.yml
# Review and commit the change before creating feature worktrees.
```

This opt-in operation preserves the application's original database names as
fallbacks when Gitwo is inactive, and saves a private backup outside the Git
repository. It refuses dirty, symlinked, ERB-customized, URL-based or
multi-database configurations rather than guessing. It does not commit changes.

The resulting conventional configuration has entries like:

```yaml
development:
  <<: *default
  database: <%= ENV.fetch("GITWO_DB_DEV", "my_app_development") %>
test:
  <<: *default
  database: <%= ENV.fetch("GITWO_DB_TEST", "my_app_test") %>
```

For complex Rails configurations, perform the integration manually and preserve
the app's existing connection settings. Applications using a `url:` entry can
select `GITWO_DEV_DATABASE_URL` and `GITWO_TEST_DATABASE_URL` per environment.
These local URLs contain no password; libpq uses `PGHOST`, `PGPORT`, `PGUSER`
and your existing credential mechanism.

Gitwo **never edits tracked database.yml during workspace creation, setup,
verification, or direnv activation**. Only `integrate --apply` can do so.

### Ignored `config/database.yml` (developer-local projects)

When `config/database.yml` is explicitly ignored by Git in the primary checkout,
Gitwo can prepare an isolated copy in each new workspace without modifying the
source checkout or Git history. If the ignored file exists, it is copied using
the existing safe local-file rules; Gitwo updates only its conventional
`development` and `test` `database:` entries, with the isolated workspace
database names as fallbacks. A legacy development-only file can have a `test`
block derived from development. If an ignored file is absent, a small PostgreSQL
development/test config is generated **only inside the workspace**.

Custom ERB, nested multi-DB layouts, explicit `url:` entries and symlinked
configurations are refused rather than guessed at. Untracked but **not ignored**
configurations are preserved without rewriting. A **tracked** `database.yml`
is never rewritten by automatic workspace setup.

Inspect the detection result before adopting a project:

```sh
gitwo detect --json
```

Look at `detected.database_config.value`:
`tracked`, `ignored`, `ignored_missing`, `untracked`, `missing`
or `symlink`. Developers do not need to edit `database.yml` for each feature
when it is ignored and has a conventional Rails layout.

**Readiness contract:** successful full setup requires creation and real
connectivity checks of **both** isolated development and test databases.
Gitwo checks each PostgreSQL database and each live Rails ActiveRecord
connection, including custom `config_for(:database)` targets when detected.
The `bootstrap-status=ready` marker is written only after verification.
`gitwo new --no-setup` creates a worktree, **not** a ready Rails environment.

## 2. Create and initialize a workspace

```sh
gitwo workspace create feature ENG-123
# Alias: gitwo new feature ENG-123
```

After Rails setup, Gitwo checks the **native** Rails development and test
connections. If either points to a different DB, Gitwo does not generate an
activation file. Fix the app config and run:

```sh
gitwo workspace env init
```

`init` reserves workspace ports, optionally starts isolated Redis when configured,
verifies both Rails database targets, then creates an ignored local `.envrc`.
`verify` requires pre-existing port allocations and does not start services,
create files, or modify Gitwo-managed state. Both commands boot the trusted Rails
application to inspect ActiveRecord; app initializers might have side effects.
Existing tracked and ignored `.envrc` files are preserved as application
configuration, with no required `source_env` line. If one exists, `gitwo new`
skips Gitwo's own direnv activation rather than replacing the app's rules.
Use `gitwo run WORKSPACE rails ...` for a verified isolated Rails command.
Native activation is optional and must be verified separately.
See [application ENV compatibility](application-env.md).

To inspect again without writing `.envrc` or allocating ports or starting Redis:

```sh
gitwo workspace env verify
```

## 3. Enable automatic activation once

Install `direnv` with your system package manager and add this to `~/.zshrc`:

```sh
eval "$(direnv hook zsh)"
```

For bash, use `eval "$(direnv hook bash)"`. Review the `.envrc` and approve it:

```sh
cat .envrc
direnv allow .
```

**Gitwo never runs `direnv allow` automatically.** `direnv` unloads these
variables automatically when leaving the workspace, including when switching
to a different Gitwo project. You can re-check with `direnv status`.

## 4. Work normally

```sh
bin/rails server
bin/rails console
bin/rails db:migrate
bin/rails test
bundle exec rspec
```

`PORT` is reserved per workspace for a direct Rails server. To run the server
through Portless HTTPS instead, use `gitwo up` or invoke Portless explicitly;
ordinary `bin/rails server` does not register itself with Portless.

Workspace-specific variables include `GITWO_DB_DEV`, `GITWO_DB_TEST`,
`GITWO_DEV_DATABASE_URL`, `GITWO_TEST_DATABASE_URL`, `GITWO_DEV_REDIS_URL`,
`GITWO_TEST_REDIS_URL`, `PGHOST`, `PGPORT`, `PGUSER`, `PORT`, and `APP_HOST`.
Neither `RAILS_ENV` nor `DATABASE_URL` is exported, allowing Rails test runners
to choose test naturally. This is intentional and must not be "simplified".

**Redis requires application-level environment selection.** Gitwo does
not globally export `REDIS_URL` or `SIDEKIQ_REDIS_URL`, because test suites may
clear them. For a Redis client, an illustrative Rails configuration is:

```ruby
workspace_redis_url = if ENV.key?("GITWO_DEV_REDIS_URL") && ENV.key?("GITWO_TEST_REDIS_URL")
  Rails.env.test? ? ENV.fetch("GITWO_TEST_REDIS_URL") : ENV.fetch("GITWO_DEV_REDIS_URL")
else
  ENV.fetch("REDIS_URL", "redis://127.0.0.1:6379/0")
end
```

Pass `workspace_redis_url` to your app's Redis/cache/Sidekiq clients as
appropriate; the exact integration depends on the application's own settings.
Do not blindly change tracked Redis initializers. Sidekiq workers can invoke
external services, so only start trusted workers after reviewing integrations.
The hosted Rails E2E verifies a real Redis client can use distinct development
and test instances and that the test suite preserves a development-only key.

Your Ruby version must be installed with mise. The activation loader adds the
selected Ruby's `bin/` directory to `PATH` without altering tracked files.

## 5. Safety properties

- No changes to tracked Rails binstubs, tracked `config/database.yml`, or committed files. Ignored workspace-local `database.yml` may be created or specialized.
- `.envrc` is generated only after both DB targets pass real Rails checks.
- `.envrc` is ignored locally through Git's `info/exclude`, without changing
  repository `.gitignore`.
- A pre-existing `.envrc` is never overwritten or automatically approved.
- Loading the directory environment does not execute Rails, run seeds, or
  start processes; setup and explicit `workspace env init` handle resource prep.
- Standard `gitwo run ...` remains available for compatibility and one-off
  commands in another workspace, but is not needed for normal daily work.
- If direnv is not installed, direct commands are **not** claimed isolated;
  install/approve direnv before running destructive Rails DB tasks.

## Managed Rails runtime launcher

`gitwo up` uses the project's existing development entrypoint when available.
The deterministic selection order is an executable, non-symlinked `bin/dev`,
then an explicit `Procfile.dev` using an installed Overmind or Foreman,
and finally the standard `bundle exec rails server` fallback. A Procfile
without a `web:` process is rejected. When a process manager is missing,
Gitwo refuses to silently launch only Rails, since that would omit required
processes. An explicit `--launcher=rails` override is available for debugging.

```bash
gitwo up --dry-run --json
gitwo up --launcher=auto
gitwo up --launcher=rails
```

The managed launcher inherits isolated Rails `DATABASE_URL`, Redis URLs,
`APP_HOST`, `GITWO_APP_URL` and the selected `PORT`. Under Portless,
the child launcher receives Portless's dynamically assigned `PORT`. When
running Foreman or Overmind directly, Gitwo passes that port with `-p`.
`bin/dev` remains responsible for respecting inherited `PORT` if it
specifies its own process-manager arguments.

`gitwo up --dry-run --json` is side-effect-free and returns the launcher
choice. `gitwo up --json` is a foreground process: it emits a single
`status: starting` JSON event to stdout, sends application logs to stderr,
and exits with the process's status. That event is **not** a health check.
Non-interactive invocations never prompt for ownership adoption; they refuse
unregistered existing DBs. Detached process supervision is deferred.

For Vite, Portless routes the web process and provides a hostname and HTTP
port. Gitwo does **not** rewrite a Vite config and cannot guarantee HMR
WebSockets work without a project-specific HMR host/proxy configuration.
The launcher warns when it sees common Vite config filenames.

`gitwo down` still verifies and terminates workspace-owned Puma/Sidekiq
processes, but it does not yet supervise an externally started
Foreman/Overmind process group. Keep multi-process `gitwo up` in the
foreground and stop it with Ctrl-C so the process manager can cleanly stop
its own children. Do not rely on `gitwo down` to stop arbitrary frontend
or process-manager children.

## Existing developer Compose files and Dev Containers

`gitwo detect --json` includes a stable `notices` array when project
Compose or Dev Container configs are detected but **not configured to run**.
Each notice carries `code`, `status: detected_not_configured`, `files` and
`message`, so an agent can act on it without scraping terminal output.
`gitwo detect` and `gitwo init` show an explicit `[NOTICE]` for each detected
unsupported runtime. If a developer selects Gitwo-managed Compose during
`init`, a second notice clarifies that it provisions only Gitwo-owned
PostgreSQL/Redis, not the project's own Compose application or Dev Container.

`gitwo detect --json` inventories common developer Compose files such as
`compose.local.yml`, `compose.dev.yml`, `docker-compose.development.yaml`,
and `docker-compose.override.yml`, plus Dev Container definitions in
`.devcontainer/devcontainer.json`, `.devcontainer/<profile>/devcontainer.json`,
and `.devcontainer.json`. It also recognizes conventional Compose filenames
inside `.devcontainer/`. Detection reads **filenames only**, does not run Docker
or Dev Container lifecycle hooks, and ignores symlinked entries.

The detected application Compose files are NOT the same as Gitwo's managed
`services.backend: compose`. Managed Compose provisions an isolated PostgreSQL
and Redis stack outside the application repository; it does **not** run or attach
to the developer's custom Compose services. Dev Container startup, workspace
mount mapping, in-container CLI execution, and reuse of an existing project's
Compose network are **not implemented** in this release. They require an
explicit adapter and lifecycle/ownership safeguards; detection is the first,
read-only compatibility step.

## Service backend: native or managed Compose

`gitwo detect --json` reports Compose files at the repository root without
executing them. `gitwo init` offers `services.backend: native|compose`. The
noninteractive default is **native**, even if an application Compose file exists.

For `compose`, Gitwo generates its own private Compose file in the selected
workspace state directory. It does not read or run the application's `compose.yml`.
Each workspace gets its own Compose project name, PostgreSQL 16 volume, Redis
for development/test, and published loopback ports. The selected PostgreSQL
password is stored in an owner-readable state file and exported by direnv for
native Rails commands. `gitwo services down` leaves the DB volume intact.

```sh
gitwo services up develop-1
gitwo services status develop-1
gitwo services down develop-1
```

This does not remove the need for environment-specific `config/database.yml` and
Redis settings while Rails is running on the host. Do not use Docker Compose's
`down -v` unless intentionally deleting the workspace's persistent data.

For native `bin/rails server` through Portless, register one static alias after
reviewing/allowing the workspace `.envrc`:

```sh
gitwo workspace proxy register develop-1
bin/rails server
gitwo workspace proxy status develop-1
gitwo workspace proxy unregister develop-1
```

These aliases use an existing reserved `PORT`; they are not registered inside
`direnv`, and `gitwo up` must not be run concurrently while a static alias is
registered. The registration refuses existing foreign routes and never stops the
shared Portless proxy.
