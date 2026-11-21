# Dependencies and CI audit (2026-11-21)

Gitwo itself is Bash with small Ruby standard-library helpers. It does not
ship a Gemfile, Node package or runtime package lock. Application code and
bundler dependencies belong to each project, not Gitwo.

## Runtime requirements

| Dependency | Why it is used | Policy |
| --- | --- | --- |
| Git + Bash | Git worktrees and shell CLI | Required |
| Ruby (3.3 in CI) | YAML, JSON, onboarding, issue providers | Required; stdlib only |
| PostgreSQL CLI and local server | Rails database isolation, dumps | Required for PostgreSQL projects only |
| Bundler + Rails | Run the user's Rails app | Project-managed |
| mise | Select tool versions for Rails processes | Required for Rails runtime currently |
| Redis | Workspace Redis process and Sidekiq | Only when configured |
| Node.js + Portless | Local hostname and HTTPS proxy | Optional |
| gh | Authenticated GitHub Issues lookup | Only for GitHub issue provider |
| curl / OpenSSL | HTTP, TLS and provider access | Provider-dependent |
| yarn / webpack | Legacy Rails adapter | Only for legacy Webpack projects |

## CI dependencies

| Dependency | CI pin / source | Status |
| --- | --- | --- |
| actions/checkout | SHA of v6 | Pinned full SHA |
| ruby/setup-ruby | SHA of v1.343.0 | Pinned full SHA |
| jdx/mise-action | SHA of v4 | Pinned full SHA |
| actions/setup-node | SHA of v6 | Pinned full SHA |
| Ruby | 3.3.14 | Explicit fixture version |
| Rails | 7.2.4 | Explicit last Rails 7.2 release; compatibility fixture, EOL series |
| Node.js | 24 | Pinned major/LTS line |
| PostgreSQL | Docker image postgres:16, Homebrew postgresql@16 | Pinned major; image digest not pinned |
| Redis | Ubuntu apt / macOS Homebrew | Floating OS package version |
| Portless | npm portless@0.18.1 | Pinned exact direct version; transitive npm deps not lockfile-pinned |
| Bundler gems | Generated Rails fixture, bundle install | Transitive versions resolved during CI |

## Gaps and follow-up

- Rails 7.2 has ended security support. It is used as a compatibility fixture,
  not recommended as a baseline for production apps. Add a supported Rails 8.1
  fixture in a separately budgeted CI matrix before a stable release.
- The PostgreSQL image is major-version pinned, not digest pinned.
- `brew`, `apt`, RubyGems and the global Portless npm dependency tree are not
  locked. Add SBOM/provenance and an integrity-locked bootstrap for release
  builds, rather than falsely treating them as immutable.
- Prefer `dependabot` for reviewed updates to GitHub Actions, but retain full
  SHAs and re-run all stages for each update.

## CI execution order (cheap to expensive)

1. Static syntax + dependency policy (Ubuntu): no services.
2. Linux regression + installer: project-agnostic mocks and local fixtures.
3. macOS regression + installer: portability smoke, no databases.
4. Linux Rails E2E: real PostgreSQL/Redis, seeds, dump, restore, Puma.
5. macOS Rails HTTPS E2E: Homebrew databases, Portless CA and HTTPS.

Stages 3 and 4 can run concurrently after stage 2 to save wall-clock time.
Stage 5 is gated on both. The old separate workflows are consolidated to
avoid duplicate push/PR executions. Use GitHub Actions step durations to
replace these relative estimates with measured medians after several runs.
