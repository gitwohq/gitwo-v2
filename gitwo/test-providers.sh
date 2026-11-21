#!/usr/bin/env bash
# Offline provider contract checks. Never reaches real Jira, Linear or GitHub.
set -euo pipefail
script="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/gitwo-providers.XXXXXXXX")"
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/home/.config/gitwo/credentials/work"
export HOME="$tmp/home" XDG_CONFIG_HOME="$tmp/home/.config"
# Mock gh api, including explicit PR detection.
cat > "$tmp/bin/gh" <<'SH'
#!/usr/bin/env bash
[[ "${1:-}" == api && "${2:-}" == repos/acme/widget/issues/12 ]] || exit 3
if [[ "${MOCK_PULL_REQUEST:-}" == 1 ]]; then
  printf '{"number":12,"title":"Pull request","pull_request":true}\n'
else
  printf '{"number":12,"title":"Fix import job","pull_request":false}\n'
fi
SH
chmod +x "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH"
export GITWO_ISSUE_PROVIDER=github GITWO_ISSUE_URL=https://github.com/acme/widget
[[ "$(ruby "$script/provider.rb" key '#12')" == GH-12 ]]
[[ "$(ruby "$script/provider.rb" resolve '#12')" == 'GH-12|fix-import-job' ]]
if MOCK_PULL_REQUEST=1 ruby "$script/provider.rb" resolve '#12' > "$tmp/pr-output" 2> "$tmp/pr-error"; then
  echo 'Expected GitHub PR refusal' >&2; exit 1
fi
grep -q 'Pull Request' "$tmp/pr-error"
# Jira key parsing and manually supplied title are offline.
export GITWO_ISSUE_PROVIDER=jira
[[ "$(ruby "$script/provider.rb" key ENG-123)" == ENG-123 ]]
[[ "$(ruby "$script/provider.rb" resolve ENG-123 --offline)" == 'ENG-123|' ]]
# Linear GraphQL client using in-process HTTP stub; no network.
export GITWO_ISSUE_PROVIDER=linear LINEAR_API_KEY=testing_token
ruby -I "$script" -r provider - <<'RUBY'
module Net
  class HTTP
    def self.start(*args)
      fake = Object.new
      def fake.request(req)
        abort 'not GraphQL POST' unless req.method == 'POST'
        abort 'key not supplied' unless req['Authorization'] == 'testing_token'
        abort 'wrong identifier' unless req.body.include?('ENG-9')
        response = Net::HTTPOK.new('1.1', '200', 'OK')
        response.instance_variable_set(:@read, true)
        response.body = '{"data":{"issue":{"identifier":"ENG-9","title":"Fix the sync"}}}'
        response
      end
      yield fake
    end
  end
end
abort 'linear lookup failed' unless GitwoProvider.resolve('ENG-9') == ['ENG-9', 'fix-the-sync']
RUBY
# Private per-project token profiles enforce 0600 and never evaluate arbitrary shell.
cat > "$tmp/home/.config/gitwo/credentials/work/linear.env" <<'TXT'
LINEAR_API_KEY=private_test_token
TXT
chmod 600 "$tmp/home/.config/gitwo/credentials/work/linear.env"
unset LINEAR_API_KEY
GITWO_CREDENTIAL_PROFILE=work bash -c 'source "$1"; _gitwo_provider_credentials linear; [[ "$LINEAR_API_KEY" == private_test_token ]]' bash "$script/provider-env.sh"
chmod 644 "$tmp/home/.config/gitwo/credentials/work/linear.env"
if GITWO_CREDENTIAL_PROFILE=work bash -c 'source "$1"; _gitwo_provider_credentials linear' bash "$script/provider-env.sh" 2> "$tmp/permissions-error"; then
  echo 'Expected group-readable token rejection' >&2; exit 1
fi
grep -q 'group/world-readable' "$tmp/permissions-error"
printf '[PASS] GitHub issue + PR, Jira offline, Linear GraphQL, private credential profiles\n'
