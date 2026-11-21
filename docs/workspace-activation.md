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
Existing `.envrc` files are left untouched. If a project already tracks an
`.envrc`, review it and add the displayed `source_env` line yourself.

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
