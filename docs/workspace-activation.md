# Native Rails development in a Gitwo workspace

Gitwo owns workspace creation, setup and resource lifecycle. `direnv` owns the
per-directory shell environment. Rails, Minitest, RSpec and Sidekiq still use
their standard commands.

## 1. Configure Rails database isolation once

Rails sees the same `DATABASE_URL` in development and test if it is exported for
the whole directory. Exporting a development URL unconditionally is unsafe:
`bin/rails test` or `bundle exec rspec` could use or reset the development DB.

Instead, make your application's tracked `config/database.yml` choose a database
per environment. For a simple PostgreSQL configuration, the relevant entries can
look like this (retain your application's existing `default` settings):

```yaml
# Existing settings such as adapter, pool, encoding remain unchanged.
development:
  <<: *default
  database: <%= ENV.fetch("GITWO_DB_DEV", "my_app_development") %>

test:
  <<: *default
  database: <%= ENV.fetch("GITWO_DB_TEST", "my_app_test") %>
```

Replace the fallback names with your actual Rails database names. Applications
using a `url:` entry can instead select `GITWO_DEV_DATABASE_URL` and
`GITWO_TEST_DATABASE_URL` per environment. These are **nonsecret local URLs**;
libpq uses `PGHOST`, `PGPORT`, `PGUSER`, and your existing credential mechanism.

Gitwo **does not modify tracked database.yml**. The one-time integration can be
committed and is backward compatible because the environment variables are
absent outside Gitwo workspaces.

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

This reserves workspace ports, optionally starts isolated Redis when configured,
verifies both Rails database targets, then creates an ignored local `.envrc`.
Existing `.envrc` files are left untouched. If a project already tracks an
`.envrc`, review it and add the displayed `source_env` line yourself.

To inspect again without writing `.envrc`:

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

**Redis requires similar application-level environment selection.** Gitwo does
not globally export `REDIS_URL` or `SIDEKIQ_REDIS_URL`, because tests may clear
those Redis databases. Configure your Rails Redis clients to choose
`GITWO_TEST_REDIS_URL` in `Rails.env.test?`, otherwise
`GITWO_DEV_REDIS_URL`. Outside Gitwo, preserve your normal Redis fallback.
Sidekiq workers can execute external integrations, so only start trusted workers
once their application configuration is verified.

Your Ruby version must be installed with mise. The activation loader adds the
selected Ruby's `bin/` directory to `PATH` without altering tracked files.

## 5. Safety properties

- No modifications to Rails binstubs, `config/database.yml`, or committed files.
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
