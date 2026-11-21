#!/usr/bin/env bash
# Compatibility wrapper for Jira-only commands. New workflows use provider-env.sh.
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/provider-env.sh"
gitwo_load_jira_env() { _gitwo_provider_credentials jira; }
gitwo_jira_resolve() ( gitwo_load_jira_env && GITWO_ISSUE_PROVIDER=jira ruby "$GITWO_DIR/provider.rb" "$@"; )
