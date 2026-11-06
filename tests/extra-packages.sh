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

# The package-name rule is written twice — provision.sh's check_packages for
# the names it hands apt-get, bin/homefield's preset manifest loop for the
# names it merges — and the two must stay the same regex.
# shellcheck disable=SC2016  # the literal \$pkg is the point of the sed
prov_re="$(sed -n 's/.*if ! \[\[ "\$pkg" =~ \(.*\) \]\]; then/\1/p' "$ROOT/vm/provision.sh" | head -1)"
# shellcheck disable=SC2016  # the literal \$pkg is the point of the sed
host_re="$(sed -n 's/.*\[\[ "\$pkg" =~ \(.*\) \]\] ||.*/\1/p' "$ROOT/bin/homefield" | head -1)"
record "the package-name regex is the same in provision.sh and bin/homefield" "yes" \
  "$([ -n "$prov_re" ] && [ "$prov_re" = "$host_re" ] && echo yes || echo no)"

summary
