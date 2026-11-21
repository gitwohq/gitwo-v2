#!/usr/bin/env bash
# Read-only auto-detection for a Rails Git checkout.
set -euo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
exec ruby "$root/onboard.rb" detect "$@"
