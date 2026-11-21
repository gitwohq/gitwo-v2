# Targeted security review - 2026-11-21

Reviewed the Bash/Ruby CLI, installer, YAML loader, provider credentials,
workspace state, port allocation and Rails/Portless integration. This is
**not** an independent security audit or penetration test.

## Findings fixed
- Workspace .env state was executed with source. It is now parsed as literal
  allowlisted values, with duplicate/unknown keys refused.
- Runtime .ports was executed with source. Ports are now read as validated
  numeric data rather than shell commands.
- status --check-http used curl -k. HTTPS health checks now use the
  Portless CA or the operating-system trust store.
- New regression coverage exercises malicious runtime metadata.

## Existing safeguards reviewed
- Credential files require owner-only permissions and are separate from YAML.
- YAML is safely parsed and configuration values are validated.
- PostgreSQL endpoint is restricted to loopback by default.
- Sidekiq remains opt-in; destructive database operations require confirmation.
- Installations use checksums, staged copies, symlink checks and backups.

## Residual risks
- Rails seeds/tasks, dependencies and native tools are arbitrary user-level
  code by design. Gitwo is not a sandbox.
- Portless adds a local CA and may use sudo; only run on trusted machines.
- Installer hashes from the same download detect corruption, not a malicious
  publisher. Signed releases and pinned Action SHAs are future hardening.
- CI uses a synthetic Rails app, not private customer code or credentials.
- macOS Portless HTTPS is not verified until the new hosted workflow succeeds.
