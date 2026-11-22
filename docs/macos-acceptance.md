# Gitwo pre-release acceptance on macOS

Hosted CI uses **synthetic** Rails fixtures. Passing CI does not validate an
existing private Rails repository, local credentials, Homebrew services or
custom Rails initialization. The first Mac rollout should be explicit and
reversible. Prefer a disposable local Rails application without production
credentials for the first full setup.

## Before using a real project

1. Record `git status --short` and preserve all local work.
2. Obtain Gitwo from a reviewed local checkout or verified release artifact.
   Do not run remote install scripts without inspecting them.
3. Install using the repository's `install.sh` after verifying SHA256SUMS.
4. From a trusted Rails checkout, run `gitwo doctor --deps`,
   `gitwo detect --json` and `gitwo init --scope=local --dry-run`.
5. Check any existing `.env*`, `.envrc` and credentials conventions. Gitwo
   preserves ignored development/test files; it does not copy
   staging/production ENV or replace application direnv rules.
6. Check the application's initializers and integrations before allowing Rails
   setup to run. Isolating PostgreSQL/Redis does not prevent all external
   network calls, jobs or side effects.

No Jira account, GitHub Issues, Git remote or project `gitwo.yml` is required.

## Named feature smoke test

From the root of a disposable, trusted Rails checkout:

```sh
git status --short
gitwo detect --json
gitwo new feature mac-smoke --preview
gitwo new feature mac-smoke
gitwo list
gitwo status mac-smoke-1
gitwo run mac-smoke-1 rails runner 'puts Rails.version'
gitwo env mac-smoke-1
gitwo remove mac-smoke-1 --dry-run
git status --short
```

The second `gitwo new` command performs **full Rails setup** by default:
Bundler, isolated development/test PostgreSQL and configured Redis. Do not
run `--no-setup` for this acceptance test. Ensure both databases differ from
the primary checkout's database. Never use a real customer database or
production credential set for this first test.

If the app has a tracked/ignored `.envrc`, Gitwo preserves it and skips
generating a replacement. Use `gitwo run` for an isolated Rails command;
**do not assume** ordinary `bin/rails` is isolated. If the app has no
`.envrc`, Gitwo can optionally generate a local direnv activation **only after**
the native development and test database targets are verified. Manual
`gitwo workspace env integrate --apply` is not required for `gitwo run`.

If you test native activation separately, review the generated file and allow
it explicitly with `direnv allow .`. Verify both development and test
database targets before any destructive test command.

For multi-workspace runtime testing, create `mac-smoke` again to obtain
`mac-smoke-2`. Then verify separate Redis ports and Rails servers. For
Compose, confirm `gitwo services down mac-smoke-1` does not affect the second
workspace and retains its database volume. Review removal with `--dry-run`;
do not use `--delete-db` or `--delete-ignored` initially.

## Stop conditions and rollback

Stop if a connection targets a non-local/production database, a real customer
account or unexpected external integration, or if a tracked file changes
unexpectedly. A pre-existing `.envrc` is **not** an error; overwriting one
would be. Do not force cleanup, delete Compose volumes, stop foreign processes
or change shared Portless routes.

An earlier global Gitwo installation is backed up during installation.
Restore only after stopping Gitwo-owned processes and reviewing backups.
Persistent workspace state and PostgreSQL databases remain intact.

## Sign-off evidence

Record macOS/CPU architecture, Docker Desktop/Compose, PostgreSQL, Redis,
Rails, Ruby/mise, Portless versions, workspace paths, database names, tests
and any error logs. On-device acceptance remains necessary before a public
GitHub Release.
