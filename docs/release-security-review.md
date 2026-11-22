# Gitwo release security review (2026-11-21)

## Scope

Reviewed the Bash/Ruby CLI entrypoints, installers, project YAML parser,
credential loader, workspace state, runtime ports and Rails/Portless bridge.
This is a targeted code review, not a formal third-party penetration test.

## Findings and fixes

- **Fixed:** workspace `.env` state was evaluated by `source`, allowing local
  metadata content to execute commands. It is now parsed through a strict
  allowlist of generated keys and literal values.
- **Fixed:** runtime `.ports` data was evaluated by `source`. The existing
  numerical validation is now combined with key-specific data parsing.
- **Fixed:** `status --check-http` disabled certificate verification using
  `curl -k`. It now validates the Portless CA or OS trust store.
- **Added:** regression test with malicious state payloads that must never run.
- **Verified:** API credentials are separated from versioned YAML and private
  credential files must be owner-only. YAML parsing uses safe loading.
- **Verified:** database hosts are constrained to loopback and automatic
  Sidekiq execution remains disabled by default.
- **Verified:** installer checks file hashes, refuses symlinked install targets
  and stages the package before replacing the installed copy.

## Residual risks

- Trusted Rails tasks, seeds, Bundler hooks, Sidekiq jobs, native executables,
  and third-party tools are still arbitrary developer-level code by design.
- Portless adds a local CA to the trust store and may elevate privileges to
  bind port 443. Run it only after reviewing the host trust implications.
- Manual `gitwo run rails ...` tasks are not an application-level sandbox.
- Downloading a package with a checksum manifest from the **same untrusted
  source** detects corruption, not malicious publication. Releases should
  include signed provenance and pinned dependencies in a later milestone.
- GitHub Actions are pinned to reviewed full commit SHAs. Remaining floating dependencies include OS package indexes, the PostgreSQL 16
  container image, and dynamically resolved RubyGems transitive dependencies.
- The integration suite exercises a synthetic Rails app, not customer code or
  private provider credentials.

## Release gate

Portless HTTPS E2E passed on hosted macOS and Rails/PostgreSQL/Redis E2E passed on hosted Ubuntu.
The fixture is synthetic, and no independent security audit has been performed. Do not claim all security risks are eliminated.


## Release candidate verification (2026-11-22)

- Synthetic Rails 8.1.4.1 end-to-end jobs cover native and managed Compose services.
- Five parallel Compose workspaces are checked for unique reserved ports.
- Stopped Compose workspaces pass safe removal dry-runs; unknown/running services remain blocked.
- Runtime `.ports` metadata now rejects duplicate/missing keys and invalid TCP port values.
- Release archives are built from committed tracked files, SHA-256 hashed,
  extracted and installed in Linux and macOS CI. Modified package contents are rejected.
- Package hashes provide integrity, **not authenticated publisher provenance**.
  Signing/attestations and physical Mac acceptance remain outstanding gates.
