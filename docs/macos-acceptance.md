# Gitwo pre-release acceptance on macOS

The hosted CI uses **synthetic** Rails fixtures. Passing CI does not validate an
existing private Rails repository, local credentials, Homebrew services, or
custom Rails initialization. The first rollout on a developer Mac must be
explicit and reversible.

## Before changing a real project

1. Check `git status --short` and preserve local work.
2. Obtain the source archive and SHA-256 digest from a trusted release channel.
   Do not install an unreviewed package or run remote scripts.
3. Extract the archive and run `bash install.sh` from its root.
   Installation backs up the previous global installation and does not
   migrate older project-specific Gitwo state.
4. From a trusted Rails checkout run `gitwo doctor --deps`,
   `gitwo detect --json`, and `gitwo init --dry-run`.
5. If `config/database.yml` is conventional, inspect
   `gitwo workspace env integrate --dry-run`, then optionally `--apply`.
   Commit reviewed Rails configuration changes yourself.

## Smoke test with disposable data

- Create `develop-1` and `develop-2`, initially with `--no-setup` if you only
  want to inspect naming. Verify their distinct directories and branch names.
- Complete setup and check development/test database names and Redis URLs.
- Review the generated `.envrc` and approve it explicitly with `direnv allow .`.
  Confirm `DATABASE_URL` and `RAILS_ENV` do not leak into tests.
- Run `bin/rails runner`, `bin/rails test`, and/or `bundle exec rspec`,
  confirming each command targets the correct workspace database.
- Start Rails servers in both workspaces. With Portless, register HTTPS aliases
  explicitly and verify the local CA before testing HTTPS.
- In Compose mode only, run `gitwo services down develop-1`, confirm
  `develop-2` is unaffected, restart `develop-1` and check its data remains.
- Run `gitwo remove develop-2 --dry-run` and review ignored files and state.
  Do not use `--delete-db` or `--delete-ignored` during initial acceptance.

## Stop conditions and rollback

Stop when a connection targets a non-local database or a real customer account,
service ownership is unexpected, an `.envrc` already exists, or a tracked
file is unexpectedly modified. Do not force cleanup, delete Compose volumes,
stop foreign processes, or change shared Portless routes.

An earlier global Gitwo installation is backed up during installation.
Restore it only after stopping Gitwo-owned processes and reviewing backups.
Persistent workspace state and PostgreSQL databases remain intact.

## Sign-off evidence

Record macOS/CPU architecture, Docker Desktop/Compose, PostgreSQL, Redis,
Rails, Ruby/mise and Portless versions, workspace paths, test results, and
any error logs. This on-device acceptance is required before the first
public GitHub Release.
