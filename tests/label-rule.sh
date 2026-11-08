#!/usr/bin/env bash
# The routing label rule, checked at both ends: provision.sh's RUNNER_LABEL and
# routing_guard.py's --label must accept and reject the same labels. A label
# one side accepts and the other rejects is a runner no workflow can reach, or
# a check that passes for a runner that cannot be registered.
#
# It also pins the registered list to the canonical expression: provision.sh's
# RUNNER_LABELS (its built-ins plus RUNNER_LABEL) must name exactly what the
# guard's fromJSON('[...]') selects, case-insensitively — GitHub matches labels
# that way (AGENTS.md, "The routing expression is a versioned contract").
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
  if python3 "$ROOT/routing-guard/routing_guard.py" --workflows-dir "$EMPTY" \
    --label "$label" --jobs "" >/dev/null 2>&1; then
    verify=ok
  else
    verify=reject
  fi
  record "$label" "$want" "$([ "$prov" = "$verify" ] && echo "$prov" || echo "provision.sh $prov, routing_guard.py $verify")"
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

# The registered list and the expression select the same labels, derived from
# both sides so neither can drift alone: provision.sh's defaults are read from
# its settings block, then routing_guard.py prints the canonical expression for
# that label. Labels compare case-insensitively, as GitHub matches them.
norm_labels() {
  printf '%s\n' "$1" | tr ',' '\n' \
    | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' \
    | grep -v '^$' | tr '[:upper:]' '[:lower:]' | sort | paste -sd, -
}
# The sed pattern is literal: ${...} matches provision.sh's text, not a shell
# expansion here.
# shellcheck disable=SC2016
label_default="$(sed -n 's/^RUNNER_LABEL="${RUNNER_LABEL:-\([A-Za-z0-9._-]*\)}"$/\1/p' "$ROOT/vm/provision.sh")"
labels_spec="$(sed -n 's/^RUNNER_LABELS="\(.*\)"$/\1/p' "$ROOT/vm/provision.sh")"
if [ -z "$label_default" ] || [ -z "$labels_spec" ]; then
  echo "tests: could not read RUNNER_LABEL/RUNNER_LABELS defaults from vm/provision.sh" >&2
  exit 1
fi
prov_labels="${labels_spec//\$\{RUNNER_LABEL\}/$label_default}"
expr="$(python3 "$ROOT/routing-guard/routing_guard.py" --print-expression --label "$label_default")"
guard_labels="$(printf '%s\n' "$expr" | python3 -c 'import ast,json,re,sys; text=sys.stdin.read(); m=re.search(r"fromJSON\((.*?)\)", text); assert m is not None, "no fromJSON list in the expression"; print(",".join(json.loads(ast.literal_eval(m.group(1)))))')"
want="$(norm_labels "$guard_labels")"
got="$(norm_labels "$prov_labels")"
if [ -z "$want" ] || [ -z "$got" ]; then
  echo "tests: could not derive both label lists (expression '$want', provision.sh '$got')" >&2
  exit 1
fi
verdict="$([ "$want" = "$got" ] && echo same || printf 'expression %s, provision.sh %s' "$want" "$got")"
record "the registered labels match the expression's fromJSON list" same "$verdict"

summary
