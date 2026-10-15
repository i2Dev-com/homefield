#!/usr/bin/env bash
# The routing label rule, checked at both ends: provision.sh's RUNNER_LABEL and
# verify_routing.py's --label must accept and reject the same labels. A label
# one side accepts and the other rejects is a runner no workflow can reach, or
# a check that passes for a runner that cannot be registered.
#
# Run:  bash tests/label-rule.sh
set -uo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

EMPTY="$(mktemp -d)"
trap 'rm -rf "$EMPTY"' EXIT

# check <label> <want: ok|reject>
check() {
  local label="$1" want="$2" prov verify
  prov="$(provision_verdict RUNNER_LABEL "$label")"
  # An empty workflows dir, so only the label decides.
  if python3 "$ROOT/verify-routing/verify_routing.py" --workflows-dir "$EMPTY" \
    --label "$label" --expected "" >/dev/null 2>&1; then
    verify=ok
  else
    verify=reject
  fi
  record "$label" "$want" "$([ "$prov" = "$verify" ] && echo "$prov" || echo "provision.sh $prov, verify_routing.py $verify")"
}

for label in homefield-ci i2dev-ci acme.ci_2 HOMEFIELD-CI ubuntu2 macos_runner; do
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

summary
