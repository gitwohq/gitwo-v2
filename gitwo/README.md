# Gitwo

Manage independent Rails feature worktrees with isolated local PostgreSQL/Redis and optional Portless proxy.

## Install (new, standalone CLI)

```sh
unzip gitwo-v4.21.0-universal-complete.zip
bash gitwo-v4.21.0/install.sh
export PATH="$HOME/.local/bin:$PATH"
```

Gitwo CLI is installed to `~/.local/bin/gitwo`, scripts to `~/.local/share/gitwo/`.
The shell wrapper permits `gitwo checkout` and `gitwo new` to update the interactive directory:

```sh
source "$HOME/.local/share/gitwo/shell.zsh"
```

## Initialize a project

```sh
cd /path/to/rails-app

gitwo detect
gitwo init                 # Guided personal config outside Git (default)
gitwo init --scope=team    # Explicit, reviewable team YAML in the repo
gitwo init --yes           # Safe noninteractive defaults, schema only
gitwo init --dry-run       # No changes

gitwo doctor
gitwo new feature "Improve search"    # Fully prepares isolated Rails app
gitwo new feature ENG-42 --title "Fix API" --no-setup
```

Local YAML is stored outside the Git checkout under `~/.config/gitwo/projects/` by default; no repository files are modified. A team can explicitly commit `gitwo.yml` after `gitwo init --scope=team`. On startup Gitwo resolves the selected local/team scope and the canonical primary worktree. Set `GITWO_PROJECT_ROOT` outside a Git checkout. See [configuration scopes](../docs/configuration-scopes.md).

Gitwo worktrees are created in `../.gitwo-workspaces/<source-checkout-name>/`. State is stored in `~/.local/state/gitwo/projects/<project-ID>/`; it is never written into the application repo. `--dump` archives go under the configured project workspaces directory's `dumps/` subfolder.

## Named features first

`gitwo new feature improve-search` creates an isolated Rails workspace and
its development/test databases by default. It does not require an issue key,
Jira, GitHub, a Git remote, or even prior `gitwo init`. Run
`gitwo new feature` interactively to supply a name. Gitwo normalizes a
human title into a short safe slug and creates `feature/improve-search-1`
under a matching `improve-search-1` worktree. Repeating the name creates
`-2`, `-3`, etc. `--no-setup` is an explicit Git-only diagnostic or
experiment, not the default behavior. Rails setup requires the usual Ruby,
mise, PostgreSQL and optional Redis/Compose prerequisites.

A personal `gitwo init --scope=local` stores team-independent settings
outside Git; `--scope=team` optionally creates a reviewed shared YAML.
The application is not rewritten as part of init.

## Issue tracking

`issues.provider: jira` supports key lookup and Jira REST v3. Use private `~/.config/gitwo/credentials/<profile>/jira.env` (0600) or environment variables. `issues.credential` selects a nonsecret credential profile.

`issues.provider: linear` uses GraphQL lookup by identifier. Set `LINEAR_API_KEY` in your process or private `~/.config/gitwo/credentials/<profile>/linear.env` (0600).

`issues.provider: github` accepts `123`, `#123`, `GH-123`, or an issue URL. The `gh` CLI uses your existing authentication (`gh auth login`). Issue number is scoped to the selected source repository; set `issues.url: https://github.com/OWNER/REPO` for a non-GitHub Git remote.

`issues.provider: none` accepts issue-style keys (e.g. `ENG-42`) without API calls; `gitwo new develop` creates sequential standalone experiment worktrees.

## Frontend readiness evidence (opt-in)

GitWO keeps frontend discovery and runtime health intentionally separate.
`gitwo status --check-frontend --json` adds a structured
`frontend_readiness` report, without modifying application files or starting
services. Importmap returns `not_applicable`. Watcher/build-only pipelines
inspect known Rails asset output directories and distinguish
`no_build_artifacts` from `artifacts_observed`, but **do not claim that an
active watcher compiled them during this session**.

For a detected single Vite/Webpack dev server, supply an explicit local
endpoint to verify real HTTP transport and optionally an RFC6455 WebSocket
upgrade (this is **not** a full HMR functionality test):

```sh
gitwo status develop-1 --check-frontend --json
gitwo status develop-1 --frontend-url=http://127.0.0.1:5173/@vite/client --hmr-url=ws://127.0.0.1:5173/ --json
```

Probes reject remote hosts, credentials, custom domains, mixed-content HTTPS
with insecure WS and non-loopback DNS. HTTPS certificate verification stays
enabled, including Portless's trusted local CA when available. Static detection
never invokes project JS scripts. No implicit HMR URL or frontend port is
guessed. Full process/asset/HMR readiness and multi-server runtime mapping
remain work under [#19](https://github.com/gitwohq/gitwo-v2/issues/19).

## Frontend inventory (read-only)

`gitwo detect --json` and `gitwo init` now inventory independent Rails frontend
pipelines: Vite/vite_rails, legacy Webpacker, Shakapacker, Webpack/Rspack,
jsbundling-rails esbuild, CSS bundlers/watchers and Importmap. Multiple pipelines
may coexist in one checkout. Static evidence includes gem declarations, safe
package.json metadata, Procfile.dev process names and conventional config
filenames; application code, package scripts and lifecycle hooks are **never
executed**. Symlinked files are ignored.

The `detected.frontend.value.pipelines` array reports integration, bundler,
mode (`dev_server`, `watcher`, `build_only`, `no_build` or `unknown`),
process names, evidence, confidence, and explicit unverified readiness.
`notices` distinguishes unverified HMR for dev servers from initial-build
verification for watchers. An esbuild watcher or Importmap project **does not
need an HMR check**. A detected frontend is not proof that Gitwo can start it
or that its build assets are ready; supervision and real readiness remain
tracked under [#19](https://github.com/gitwohq/gitwo-v2/issues/19).

## Detached process supervision (opt-in)

`gitwo up --detach --json` launches a private process group owned by an
independent Ruby supervisor. It returns a `starting` JSON event with workspace,
launcher, PID, URL and an owner-private log path, **not** an HTTP/HMR readiness
claim. `gitwo status [WORKSPACE] --json` reports the observed dev-stack
supervision state, `gitwo logs --service=supervisor` shows captured output,
and `gitwo down` terminates only the verified supervised process group before
stopping its workspace services.

A PID alone never authorizes a signal: Gitwo also validates process-group
leadership, process start identity and a per-session token. Duplicate starts,
foreign live PIDs, symlinked or malformed metadata, and stale/orphaned state
fail closed without force-killing unknown processes.

Detached mode currently supports Rails, Foreman and `bin/dev` that keep
children in the launcher's process group. Detached Overmind is explicitly
refused because tmux sessions may live outside that group. Foreground mode,
ordinary Rails commands and manually started services remain available.
Process-group escape by arbitrary scripts cannot be safely supervised by this
adapter; full Overmind session ownership and automatic recovery stay in #19.
The returned `starting` event never guarantees frontend build/HMR readiness.

## Runtime launcher (Rails, bin/dev, Foreman and Overmind)

`gitwo up` now selects the existing project development launcher:
executable `bin/dev` first, otherwise `Procfile.dev` with installed
Overmind/Foreman, otherwise plain Rails server. It passes isolated DB/Redis
and workspace hostname/port settings to the child launcher instead of
replacing the project's process configuration.

`gitwo up --dry-run --json` inspects the selection without starting anything.
`gitwo up --json` emits a machine-readable `starting` event, sends app
logs to stderr, and stays in the foreground. The event does not claim HTTP
or HMR readiness. Use `gitwo up --launcher=rails` for explicit fallback.
Existing project Compose and Dev Container runtimes remain unsupported
until an explicit opt-in integration is added. Multi-process `gitwo up`
must be stopped with Ctrl-C; there is no managed detached supervisor yet.

## Database readiness and developer environments

A fully provisioned workspace is ready only after Gitwo verifies separate,
reachable development and test PostgreSQL databases **and** live Rails
ActiveRecord connections. `gitwo new --no-setup` reports an unprovisioned
worktree and does not claim database readiness.

`gitwo detect --json` reports whether `config/database.yml` is tracked,
ignored, absent, or unsafe. With an **ignored** local Rails config, Gitwo can
copy and safely specialize the file for each workspace, derive a missing test
section from development, or generate a minimal workspace-only configuration
if the ignored source file is absent. Tracked or unsupported custom configs are
never modified without an explicit, reviewed integration.

`gitwo detect` and `gitwo init` explicitly show `[NOTICE]` when an existing
Docker Compose or Dev Container setup is detected but is not configured to
launch through Gitwo. `gitwo detect --json` exposes the same information in
`notices` objects (`code`, `status`, `files`, `message`), making the limitation
visible to agents. Selecting the Gitwo-managed Compose backend also displays
an explicit notice that this is **not** the application's Compose stack.

Developer Compose variants (for example `compose.local.yml`,
`docker-compose.dev.yml`) and Dev Container definitions are discovered
read-only. They are not automatically executed or attached. Gitwo's managed
`services.backend: compose` remains a separately owned, isolated PostgreSQL
and Redis stack; running a project's existing Compose or Dev Container setup
is not yet supported.

See [workspace activation](../docs/workspace-activation.md).

## Safety and compatibility

Do not put API tokens in `gitwo.yml`. Credentials and project state are separate. Gitwo does not overwrite existing databases or adopt unregistered ones without confirmation. Destructive actions require explicit flags and verification.

**This standalone distribution does not migrate existing per-project installations**. Keep them installed and functional until they have been migrated separately and the databases verified. The opt-in `rails-webpack` adapter is a compatibility hook, not a guarantee that a specific legacy Rails app is supported by the generic adapter.

For commands use `gitwo --help`, `gitwo new --help`, `gitwo status` and `gitwo doctor`.

## License and security

MIT (see [LICENSE](../LICENSE)). See [SECURITY.md](../SECURITY.md) for responsible reporting and local trust boundaries. See [release security review](../docs/release-security-review.md).

## Rails tests (Minitest and RSpec)

```sh
gitwo run test                        # Auto-select when exactly one suite exists
gitwo run minitest                    # bundle exec rails test
gitwo run minitest test/models/user_test.rb
gitwo run rspec                       # bundle exec rspec
```

All commands use the selected workspace's isolated test PostgreSQL database and Redis.
If both Minitest and RSpec are present, `run test` refuses to guess; use an explicit runner.
For `rails-standard`, `gitwo setup --test` uses the same detection. The legacy
`rails-webpack` adapter retains its existing focused RSpec setup checks.

## Native Rails workspace integration

In the primary Rails checkout, run `gitwo workspace env integrate --dry-run` to
preview an environment-aware `database.yml`. Explicit `--apply` makes a tracked,
reviewable change and creates a private backup; commit it before creating the
next worktree. Run `gitwo workspace env init` in a ready worktree to prepare an
ignored `.envrc`, and approve it once with `direnv allow .`. Normal `bin/rails`,
RSpec, and Minitest commands then work without `gitwo run`. The `verify` command
does not allocate ports or start Redis. App-specific Redis clients must select
`GITWO_DEV_REDIS_URL` or `GITWO_TEST_REDIS_URL` using `Rails.env`.

See [workspace activation](../docs/workspace-activation.md).

## Runtime services

Set `services.backend: native|compose` in `gitwo.yml`. Compose is opt-in and
Gitwo-managed, with distinct per-workspace ports and database volume. The
application's own compose.yaml is never executed. See docs/workspace-activation.md
for `gitwo services up|down|status` and native Portless alias management.

## Shared team configuration

The team commits `gitwo.yml` once. New developers run `gitwo onboard --scope=team`
to check prerequisites, or `gitwo onboard --scope=team --check` for CI-only
schema validation. No repeated `gitwo init` is needed after clone.
`gitwo onboard --scope=team --setup` is an explicit, confirmed schema-only workspace
bootstrap without seeds. See [team onboarding](../docs/team-onboarding.md).
