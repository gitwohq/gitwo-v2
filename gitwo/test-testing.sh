#!/usr/bin/env bash
# Fast, dependency-free test of Minitest/RSpec selection and argument forwarding.
set -euo pipefail
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$here/_testing.sh"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/gitwo-testing.XXXXXXXX")"
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/rails-app"
cd "$tmp/rails-app"

# Record exact argument boundaries without invoking Rails or a database.
gitwo_rails() {
  local arg
  : > "$tmp/argv"
  for arg in "$@"; do printf '%s\n' "$arg" >> "$tmp/argv"; done
}

if gitwo_test_run test >"$tmp/out" 2>"$tmp/err"; then
  echo 'Expected missing-suite failure' >&2; exit 1
fi
grep -q 'No Rails test suite detected' "$tmp/err"

mkdir -p test/models
printf 'require "rails/test_help"\n' > test/test_helper.rb
gitwo_test_run test 'test/models/name with spaces_test.rb' --verbose
printf 'test\nbundle\nexec\nrails\ntest\ntest/models/name with spaces_test.rb\n--verbose\n' > "$tmp/expected"
diff -u "$tmp/expected" "$tmp/argv"
gitwo_test_run minitest test/models/widget_test.rb
printf 'test\nbundle\nexec\nrails\ntest\ntest/models/widget_test.rb\n' > "$tmp/expected"
diff -u "$tmp/expected" "$tmp/argv"

rm -rf test
mkdir -p spec/models
printf '# spec\n' > spec/spec_helper.rb
gitwo_test_run test spec/models/widget_spec.rb --format progress
printf 'test\nbundle\nexec\nrspec\nspec/models/widget_spec.rb\n--format\nprogress\n' > "$tmp/expected"
diff -u "$tmp/expected" "$tmp/argv"

mkdir -p test
printf '# test\n' > test/test_helper.rb
if gitwo_test_run test >"$tmp/out" 2>"$tmp/err"; then
  echo 'Expected ambiguous-suite failure' >&2; exit 1
fi
grep -q 'Both Minitest and RSpec detected' "$tmp/err"
gitwo_test_run minitest
printf 'test\nbundle\nexec\nrails\ntest\n' > "$tmp/expected"
diff -u "$tmp/expected" "$tmp/argv"
gitwo_test_run rspec
printf 'test\nbundle\nexec\nrspec\n' > "$tmp/expected"
diff -u "$tmp/expected" "$tmp/argv"

if gitwo_test_run unknown >"$tmp/out" 2>"$tmp/err"; then
  echo 'Expected unknown-runner rejection' >&2; exit 1
fi
printf '[PASS] Minitest/RSpec auto-selection, ambiguity safety, and argument forwarding\n'
