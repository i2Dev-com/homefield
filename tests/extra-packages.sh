#!/usr/bin/env bash
# RUNNER_EXTRA_PACKAGES validation in provision.sh. The names reach apt-get as
# arguments, so anything but a Debian package name must be refused, before
# provisioning starts.
#
# provision.sh validates settings before its root check, so as a normal user
# it stops at "run as root" for valid input and never touches the machine.
# Refuses to run as root for the same reason.
#
# Run:  bash tests/extra-packages.sh
set -uo pipefail

if [ "$(id -u)" -eq 0 ]; then
  echo "extra-packages.sh: run as a normal user; as root provision.sh would provision this machine" >&2
  exit 1
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0
fail=0

# check <value> <want: ok|reject>
check() {
  local value="$1" want="$2" got
  got="$(RUNNER_EXTRA_PACKAGES="$value" bash "$ROOT/vm/provision.sh" </dev/null 2>&1 | head -1)"
  case "$got" in
    *"run as root"*) got=ok ;;
    *RUNNER_EXTRA_PACKAGES*) got=reject ;;
    *) got="unexpected: $got" ;;
  esac
  if [ "$got" = "$want" ]; then
    echo "  ok   [${value}] (${want})"
    pass=$((pass + 1))
  else
    echo "  FAIL [${value}]: wanted ${want}, got ${got}"
    fail=$((fail + 1))
  fi
}

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

echo
echo "${pass} passed, ${fail} failed"
[ "$fail" -eq 0 ]
