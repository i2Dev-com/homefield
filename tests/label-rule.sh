#!/usr/bin/env bash
# The routing label rule, checked at both ends: provision.sh's RUNNER_LABEL and
# verify_routing.py's --label must accept and reject the same labels. A label
# one side accepts and the other rejects is a runner no workflow can reach, or
# a check that passes for a runner that cannot be registered.
#
# provision.sh validates the label before its root check, so as a normal user
# it stops at "run as root" for a valid label and never touches the machine.
# Refuses to run as root for the same reason.
#
# Run:  bash tests/label-rule.sh
set -uo pipefail

if [ "$(id -u)" -eq 0 ]; then
  echo "label-rule.sh: run as a normal user; as root provision.sh would provision this machine" >&2
  exit 1
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EMPTY="$(mktemp -d)"
trap 'rm -rf "$EMPTY"' EXIT

pass=0
fail=0

# check <label> <want: ok|reject>
check() {
  local label="$1" want="$2" prov verify
  prov="$(RUNNER_LABEL="$label" bash "$ROOT/vm/provision.sh" </dev/null 2>&1 | head -1)"
  case "$prov" in
    *"run as root"*) prov=ok ;;
    *RUNNER_LABEL*) prov=reject ;;
    *) prov="unexpected: $prov" ;;
  esac
  # An empty workflows dir, so only the label decides.
  if python3 "$ROOT/verify-routing/verify_routing.py" --workflows-dir "$EMPTY" \
    --label "$label" --expected "" >/dev/null 2>&1; then
    verify=ok
  else
    verify=reject
  fi
  if [ "$prov" = "$want" ] && [ "$verify" = "$want" ]; then
    echo "  ok   ${label} (${want})"
    pass=$((pass + 1))
  else
    echo "  FAIL ${label}: wanted ${want}, provision.sh ${prov}, verify_routing.py ${verify}"
    fail=$((fail + 1))
  fi
}

for label in local-ci i2dev-ci acme.ci_2 LOCAL-CI ubuntu2 macos_runner; do
  check "$label" ok
done
# Not one label.
for label in "a,b" "a b" "a'b" 'a"b'; do
  check "$label" reject
done
# GitHub's default labels, in any case.
for label in self-hosted Self-Hosted linux Linux windows macos macOS ubuntu x64 x86 arm ARM64; do
  check "$label" reject
done
# Hosted image names: a runner with one of these takes plain hosted jobs.
for label in ubuntu-latest Ubuntu-24.04 ubuntu-24.04-arm windows-latest macos-15 macos-latest-xlarge; do
  check "$label" reject
done

echo
echo "${pass} passed, ${fail} failed"
[ "$fail" -eq 0 ]
