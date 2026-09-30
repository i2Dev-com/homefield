#!/usr/bin/env bash
# RUNNER_EXTRA_PACKAGES validation in provision.sh. The names reach apt-get as
# arguments, so anything but Debian package names on one line must be refused
# before provisioning starts.
#
# Run:  bash tests/extra-packages.sh
set -uo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

check() { record "[$1]" "$2" "$(provision_verdict RUNNER_EXTRA_PACKAGES "$1")"; }

check "" ok
check "tree" ok
check "libssl-dev g++ python3.12-venv" ok
check "  tree   jq  " ok
check "-o" reject
check "tree -oAPT::Get::AllowUnauthenticated=true" reject
check "--allow-downgrades" reject
check "Tree" reject
check "a" reject
check "tree;id" reject
# shellcheck disable=SC2016  # the literal text is the point
check 'tree$(id)' reject
check "tree=1.0" reject
check "tree/noble" reject
check "*" reject
# `read` stops at a newline: a second line would be dropped, not checked.
check $'tree\njq' reject
check $'tree\n' reject

summary
