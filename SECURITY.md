# Security policy

## Supported versions

Gitwo is pre-release; fixes target the latest development branch. There is
no supported stable release series yet.

## Reporting vulnerabilities

Do not post exploit details, private tokens or customer data in public issues.
Prefer **Report a vulnerability** under GitHub's **Security** tab when private
reporting is enabled. Otherwise request a private channel from maintainers
without sharing the exploit details publicly.

## Local trust boundary

Gitwo runs with your user permissions. Rails code, seeds, Bundler hooks,
plugins, native tools and custom Rails tasks execute project code. A Git
checkout from an untrusted party is **not** a sandbox.

Project YAML is parsed as data, not sourced as shell code. Generated workspace
state and ports are parsed as data, with strict key/value validation.
Keep credentials outside committed gitwo.yml, in owner-readable files or ENV.
Database operations target loopback by default; Sidekiq is disabled by default.

Portless can elevate privileges to bind port 443 and installs a local CA in
the system trust store. Review that trust impact; never bypass HTTPS certificate
verification in tests or health checks.
