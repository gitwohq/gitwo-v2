#!/usr/bin/env bash
# Rails test framework selection shared by run.sh and the standard Rails adapter.
# Never run application code while detecting the framework.

gitwo_test_framework() {
  local has_minitest=no has_rspec=no

  if [[ -f test/test_helper.rb ]] || { [[ -d test ]] && [[ -n "$(find test -type f -name '*_test.rb' -print -quit 2>/dev/null)" ]]; }; then
    has_minitest=yes
  fi
  if [[ -f spec/spec_helper.rb || -f spec/rails_helper.rb ]] || { [[ -d spec ]] && [[ -n "$(find spec -type f -name '*_spec.rb' -print -quit 2>/dev/null)" ]]; }; then
    has_rspec=yes
  fi

  case "$has_minitest:$has_rspec" in
    yes:no) printf 'minitest\n' ;;
    no:yes) printf 'rspec\n' ;;
    yes:yes)
      printf 'gitwo: Both Minitest and RSpec detected. Use gitwo run minitest or gitwo run rspec.\n' >&2
      return 2 ;;
    no:no)
      printf 'gitwo: No Rails test suite detected. Expected test/test_helper.rb, *_test.rb, spec/spec_helper.rb or *_spec.rb.\n' >&2
      return 2 ;;
  esac
}

gitwo_test_run() {
  local runner="${1:?Missing test runner}"; shift
  if [[ "$runner" == test ]]; then
    runner="$(gitwo_test_framework)" || return $?
  fi
  case "$runner" in
    minitest) gitwo_rails test bundle exec rails test "$@" ;;
    rspec) gitwo_rails test bundle exec rspec "$@" ;;
    *) printf 'gitwo: Unknown Rails test framework: %s\n' "$runner" >&2; return 2 ;;
  esac
}
