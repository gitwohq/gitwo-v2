# GitWO runtime integration - release evidence

This integration consolidates process supervision from #21, frontend
readiness diagnostics from #22, and reviewed workflow action pins
from Dependabot #2, #3 and #4 into a single release candidate.

## Delivered

- Opt-in `gitwo up --detach --json` for Rails, Foreman and compatible
  `bin/dev` launchers. A private process group, session identity and
  process-start fingerprint protect `gitwo down` from foreign PIDs.
- `gitwo status --check-frontend --json` checks independent frontend
  pipelines. Importmap requires no bundler, watcher build artifacts are
  observed without reading source, and explicit local frontend endpoints
  can be probed over HTTP and a WebSocket handshake.
- Cross-platform regression suites and native/Compose/Portless Rails E2E,
  with installer checksums protecting shipped files.
- Pinned updates for actions/checkout, actions/setup-node, jdx/mise-action
  applied to the current full workflow, not an outdated Dependabot base.

## Evidence is not full readiness

| Observation | What it proves | What remains unverified |
| --- | --- | --- |
| Supervisor `starting` | Owner/session initialized | HTTP and frontend health |
| Rails HTTP status | Loopback/Portless HTTP response | User flows |
| Watcher `artifacts_observed` | Generated file exists | Current build freshness |
| WebSocket `transport_verified` | RFC6455 handshake succeeded | Actual browser HMR events |
| Importmap `not_applicable` | No bundler is necessary | App behavior |

## Explicit limits

Detached Overmind/tmux and arbitrary daemonizing `bin/dev` scripts are
not owned by this version's process-group adapter. Existing application
Compose/Dev Containers remain discovery-only (#17). Full HMR event
verification, initial build freshness and multiple active frontend server
mapping remain tracked in #19. Remote/tunnel exposure is never automatic.

## Merge gate

Only merge after complete green CI on the combined commit: static checks,
Linux/macOS regression and installer, Rails/PostgreSQL, managed Compose,
macOS Portless HTTPS, and Rails 8.1 native/Compose E2E. Do not treat
cancelled, hanging, or skipped checks as success.
