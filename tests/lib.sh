#!/usr/bin/env bash
# Shared by the suites in tests/: counters, reporting, and running provision.sh
# up to its settings checks. Source it; it does not run anything by itself.
#
# provision.sh checks its settings before its root check, so as a normal user
# it stops at "run as root" for valid input and never touches the machine.
# Sourcing this as root is refused for the same reason.

if [ "$(id -u)" -eq 0 ]; then
  echo "tests: run as a normal user; as root provision.sh would provision this machine" >&2
  exit 1
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0
fail=0

# provision_verdict <SETTING> <value>: how provision.sh takes the setting.
# Prints `ok` (got past the settings checks), `reject` (refused, naming the
# setting), or `unexpected: <first line>`, which never matches a wanted
# verdict, so a change in provision.sh's wording fails every case loudly.
provision_verdict() {
  local setting="$1" value="$2" out
  out="$(env PROVISION_SYSROOT=/nonexistent-sysroot "$setting=$value" bash "$ROOT/vm/provision.sh" </dev/null 2>&1 | head -1)"
  case "$out" in
    "provision.sh: run as root (sudo)") echo ok ;;
    "provision.sh: ${setting}"*) echo reject ;;
    *) echo "unexpected: $out" ;;
  esac
}

# record <description> <want> <got>
record() {
  if [ "$2" = "$3" ]; then
    echo "  ok   $1 ($2)"
    pass=$((pass + 1))
  else
    echo "  FAIL $1: wanted $2, got $3"
    fail=$((fail + 1))
  fi
}

# summary: prints the totals; its status is the suite's.
summary() {
  echo
  echo "${pass} passed, ${fail} failed"
  [ "$fail" -eq 0 ]
}
