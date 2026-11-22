#!/usr/bin/env bash
# Read-only local configuration management; no credentials in output.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/_common.sh"
usage() {
  printf 'Usage: gitwo config <show|path|validate|scope|use|init> [--json|local|team]\n'
  printf '  show      Display effective nonsecret configuration\n'
  printf '  path      Print the active config.yml path\n'
  printf '  validate  Validate YAML and effective options without modifying files\n  init      Create a private gitwo.yml from auto-detection (never overwrite)\n'
  printf '  scope     Show selected local/team configuration scope\n'
  printf '  use       Persist selected scope locally (local|team); no project writes\n'
  printf '  --json    Machine-readable output for show\n'
}
if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then usage; exit 0; fi
[[ $# -ge 1 && $# -le 2 ]] || { usage >&2; exit 2; }
action="$1"; shift
case "$action" in
  show) [[ $# -eq 0 || ( $# -eq 1 && "$1" == --json ) ]] || { usage >&2; exit 2; } ;;
  path|validate|init|scope) [[ $# -eq 0 ]] || { usage >&2; exit 2; } ;;
  use) [[ $# -eq 1 && ( "$1" == local || "$1" == team ) ]] || { usage >&2; exit 2; } ;;
  *) usage >&2; exit 2 ;;
esac
if [[ "$action" == init ]]; then
  exec ruby "$GITWO_DIR/onboard.rb" init --scope=local --yes
fi
if [[ "$action" == scope ]]; then
  ruby "$GITWO_DIR/config-location.rb" scope "$GITWO_SOURCE"
  exit
fi
if [[ "$action" == use ]]; then
  scope="$1"
  config="$(ruby "$GITWO_DIR/config-location.rb" "$scope" "$GITWO_SOURCE")" || exit 2
  [[ -f "$config" && ! -L "$config" ]] || { printf 'Missing or unsafe %s config: %s\n' "$scope" "$config" >&2; exit 2; }
  ruby "$GITWO_DIR/config.rb" validate "$config" >/dev/null || exit 2
  ruby "$GITWO_DIR/config-location.rb" use "$GITWO_SOURCE" "$scope" || exit 2
  printf '[OK] Activated %s scope locally. Config: %s\n' "$scope" "$config"
  exit 0
fi
if [[ -e "$GITWO_CONFIG_FILE" || -L "$GITWO_CONFIG_FILE" ]]; then
  [[ -f "$GITWO_CONFIG_FILE" && ! -L "$GITWO_CONFIG_FILE" ]] || gitwo_die "Unsafe config file: $GITWO_CONFIG_FILE"
  ruby "$GITWO_DIR/config.rb" validate "$GITWO_CONFIG_FILE" >/dev/null || exit 2
fi
case "$action" in
  path) printf '%s\n' "$GITWO_CONFIG_FILE"; exit 0 ;;
  validate)
    if [[ -f "$GITWO_CONFIG_FILE" ]]; then
      printf 'Config file: valid (%s)\n' "$GITWO_CONFIG_FILE"
    else
      printf 'Config file: absent (built-in defaults and environment overrides active)\n'
    fi
    ;;
esac
# All runtime overrides must obey the same restrictions as YAML values.
GITWO_ADAPTER="${GITWO_ADAPTER:-rails-standard}" \
GITWO_PROJECT_SOURCE="${GITWO_PROJECT_SOURCE:-$(basename "$GITWO_SOURCE")}" \
GITWO_BASE_BRANCH="${GITWO_BASE_BRANCH:-$(git -C "$GITWO_SOURCE" branch --show-current)}" \
GITWO_DB_PREFIX="${GITWO_DB_PREFIX:-${GITWO_PROJECT_SOURCE//-/_}}" \
GITWO_DUMPS_DIR="${GITWO_DUMPS_DIR:-dumps}" \
GITWO_FEATURE_BASE="${GITWO_FEATURE_BASE:-origin/$GITWO_BASE_BRANCH}" \
GITWO_HOTFIX_BASE="${GITWO_HOTFIX_BASE:-origin/$GITWO_BASE_BRANCH}" \
GITWO_DB_HOST="${GITWO_DB_HOST:-localhost}" \
GITWO_DB_PORT="${GITWO_DB_PORT:-5432}" \
GITWO_DB_USER="${GITWO_DB_USER:-${USER:-postgres}}" \
GITWO_PROXY="${GITWO_PROXY:-none}" \
GITWO_DOMAIN="${GITWO_DOMAIN:-$(basename "$GITWO_SOURCE")}" \
GITWO_GIT_WORKFLOW="${GITWO_GIT_WORKFLOW:-github-flow}" \
GITWO_ISSUE_PROVIDER="${GITWO_ISSUE_PROVIDER:-none}" \
GITWO_CREDENTIAL_PROFILE="${GITWO_CREDENTIAL_PROFILE:-default}" \
GITWO_ISSUE_URL="${GITWO_ISSUE_URL:-}" \
GITWO_FRAMEWORK="${GITWO_FRAMEWORK:-rails}" \
GITWO_HAS_SIDEKIQ="${GITWO_HAS_SIDEKIQ:-false}" \
GITWO_HAS_REDIS="${GITWO_HAS_REDIS:-false}" \
GITWO_BOOTSTRAP="${GITWO_BOOTSTRAP:-schema}" \
ruby -e '
  require "json"
  names = %w[GITWO_ADAPTER GITWO_PROJECT_SOURCE GITWO_BASE_BRANCH GITWO_DUMPS_DIR GITWO_DB_PREFIX GITWO_FEATURE_BASE GITWO_HOTFIX_BASE GITWO_DB_HOST GITWO_DB_PORT GITWO_DB_USER GITWO_PROXY GITWO_DOMAIN GITWO_GIT_WORKFLOW GITWO_ISSUE_PROVIDER GITWO_ISSUE_URL GITWO_CREDENTIAL_PROFILE GITWO_FRAMEWORK GITWO_HAS_SIDEKIQ GITWO_HAS_REDIS GITWO_BOOTSTRAP]
  values = names.to_h { |key| [key, ENV.fetch(key)] }
  values.each do |key, value|
    case key
    when "GITWO_ADAPTER" then valid = %w[rails-webpack rails-standard].include?(value)
    when "GITWO_PROJECT_SOURCE", "GITWO_DUMPS_DIR" then valid = value.match?(%r{\A[a-zA-Z][a-zA-Z0-9_-]*\z})
    when "GITWO_BASE_BRANCH" then valid = value.match?(%r{\A[a-zA-Z][a-zA-Z0-9._-]*\z}) && !value.include?("..") && !value.end_with?(".lock")
    when "GITWO_DB_PREFIX" then valid = value.match?(%r{\A[a-z][a-z0-9_]{0,20}\z})
    when "GITWO_FEATURE_BASE", "GITWO_HOTFIX_BASE"
      valid = (value.match?(%r{\Aorigin/[A-Za-z0-9][A-Za-z0-9._/-]*\z}) || value.match?(%r{\A[A-Za-z][A-Za-z0-9._-]*\z})) && !value.include?("..") && !value.include?("//") && !value.end_with?(".", "/") && !value.split("/").any? { |p| p.start_with?(".") || p.end_with?(".lock") }
    when "GITWO_DB_HOST" then valid = %w[localhost 127.0.0.1].include?(value)
    when "GITWO_DB_PORT" then valid = value.match?(%r{\A[0-9]+\z}) && value.to_i.between?(1024, 65_535)
    when "GITWO_DB_USER" then valid = value.match?(%r{\A[A-Za-z_][A-Za-z0-9_]*\z})
    when "GITWO_PROXY" then valid = %w[portless none].include?(value)
    when "GITWO_GIT_WORKFLOW" then valid = %w[gitflow github-flow trunk-based gitlab-flow custom].include?(value)
    when "GITWO_CREDENTIAL_PROFILE" then valid = value.match?(%r{\A[a-z][a-z0-9_-]{0,31}\z})
    when "GITWO_ISSUE_PROVIDER" then valid = %w[jira linear github none].include?(value)
    when "GITWO_ISSUE_URL" then valid = value.empty? || (value.size <= 256 && value.match?(%r{\Ahttps://[A-Za-z0-9.-]+(?::[0-9]{2,5})?(?:/[A-Za-z0-9._/-]*)?\z}))
    when "GITWO_FRAMEWORK" then valid = %w[rails unknown].include?(value)
    when "GITWO_HAS_SIDEKIQ", "GITWO_HAS_REDIS" then valid = %w[true false].include?(value)
    when "GITWO_BOOTSTRAP" then valid = %w[schema seeds].include?(value)
    when "GITWO_DOMAIN" then valid = value.length <= 63 && value.match?(%r{\A[a-z][a-z0-9]*(?:-[a-z0-9]+)*\z})
    end
    abort "Invalid effective value: #{key}" unless valid
  end
  if ARGV.include?("--json")
    puts JSON.pretty_generate({version: 1, config_file: ENV.fetch("GITWO_CONFIG_FILE"), source: ENV.fetch("GITWO_SOURCE"), settings: values})
  elsif ARGV.include?("validate")
    puts "Effective options: valid"
  else
    puts "gitwo / effective configuration"
    puts "  File             #{ENV.fetch("GITWO_CONFIG_FILE")}"
    puts "  Source           #{ENV.fetch("GITWO_SOURCE")}"
    values.each { |key, value| puts "  #{key.ljust(20)} #{value}" }
  end
' "$action" "${1:-}"
