#!/usr/bin/env bash
# Built-in verified adapters only; never source arbitrary repository scripts.
case "${GITWO_ADAPTER:-rails-standard}" in
  rails-webpack) source "$GITWO_DIR/adapters/rails-webpack.sh" ;;
  rails-standard) source "$GITWO_DIR/adapters/rails-standard.sh" ;;
  *) gitwo_die "Unsupported project adapter: $GITWO_ADAPTER" ;;
esac
