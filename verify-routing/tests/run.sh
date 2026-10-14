#!/usr/bin/env bash
# Fixture suite for verify_routing.py. Each case copies base/ into a scratch
# workflows dir, applies one mutation, and asserts the exit status. The
# mutations are the ways a hand-edited copy of the expression actually drifts.
#
# Run:  bash verify-routing/tests/run.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${HERE}/../verify_routing.py"
EXPECTED="ci.yml:changes ci.yml:checks"
SED_INPLACE=(sed -i)
sed --version >/dev/null 2>&1 || SED_INPLACE=(sed -i '')

pass=0
fail=0

# case <name> <want: pass|fail> <expected list> [sed expression] [job to append]
# LABEL in the environment is passed as --label; unset uses the default.
# The append form exists for multi-line YAML, which BSD and GNU sed cannot both
# write through one `s` command. Jobs are last in base/ci.yml, so an appended
# job lands under `jobs:`.
case_() {
  local name="$1" want="$2" expected="$3" mutation="${4:-}" append="${5:-}"
  local dir
  dir="$(mktemp -d)"
  cp "${HERE}/base/"*.yml "$dir/"
  if [ -n "$mutation" ]; then
    "${SED_INPLACE[@]}" -e "$mutation" "$dir/ci.yml"
    # A mutation that matches nothing would test the clean base under a
    # misleading name. Refuse it.
    if cmp -s "${HERE}/base/ci.yml" "$dir/ci.yml"; then
      echo "  FAIL ${name}: mutation matched nothing"
      fail=$((fail + 1))
      rm -rf "$dir"
      return
    fi
  fi
  if [ -n "$append" ]; then
    printf '\n%s\n' "$append" >>"$dir/ci.yml"
  fi
  local got=pass
  python3 "$SCRIPT" --workflows-dir "$dir" --expected "$expected" ${LABEL:+--label "$LABEL"} >"$dir/out" 2>&1 || got=fail
  if [ "$got" = "$want" ]; then
    echo "  ok   ${name} (${got})"
    pass=$((pass + 1))
  else
    echo "  FAIL ${name}: wanted ${want}, got ${got}"
    sed 's/^/       /' "$dir/out"
    fail=$((fail + 1))
  fi
  rm -rf "$dir"
}

case_ "clean base passes"                pass "$EXPECTED"
case_ "hosted fallback dropped"          fail "$EXPECTED" "s/ || 'ubuntu-latest' }}/ }}/"
case_ "pull-request-only rule dropped"   fail "$EXPECTED" "s/github.event_name == 'pull_request' \&\& //"
case_ "Dependabot actor check dropped"   fail "$EXPECTED" "s/github.actor != 'dependabot\[bot\]' \&\& //"
case_ "Dependabot branch check dropped"  fail "$EXPECTED" "s/!startsWith(github.head_ref, 'dependabot\/') \&\& //"
case_ "fork guard dropped"               fail "$EXPECTED" "s/github.event.pull_request.head.repo.full_name == github.repository \&\& //"
case_ "fork guard weakened to !="        fail "$EXPECTED" "s/head.repo.full_name == github.repository/head.repo.full_name != github.repository/"
case_ "bare self-hosted job"             fail "$EXPECTED" "s/^    runs-on: ubuntu-latest$/    runs-on: [self-hosted, linux, arm64]/"
case_ "label in a step, not routing"     pass "$EXPECTED" "s/^      - run: echo docker$/      - name: Verify self-hosted local-ci routing/"
case_ "opted-in job not in expected"     fail "ci.yml:changes"
case_ "expected job not opted in"        fail "$EXPECTED ci.yml:docker"
case_ "job id with trailing comment"     pass "$EXPECTED" "s/^  checks:$/  checks: # lint and test/"
case_ "quoted job id, not expected"      fail "ci.yml:changes" "s/^  checks:$/  \"checks\":/"
case_ "quoted job id, expected"          pass "$EXPECTED" "s/^  checks:$/  'checks':/"
# Ways to reach the runner without writing `self-hosted` or the label as-is.
# GitHub matches labels case-insensitively and by superset, and the runner is
# in the local-ci group, so each of these would run unguarded on the VM.
case_ "Self-Hosted in other case"        fail "$EXPECTED" "s/^    runs-on: ubuntu-latest$/    runs-on: Self-Hosted/"
case_ "label in other case"              fail "$EXPECTED" "s/^    runs-on: ubuntu-latest$/    runs-on: [self-hosted, LOCAL-CI]/"
case_ "default labels only"              fail "$EXPECTED" "s/^    runs-on: ubuntu-latest$/    runs-on: [linux, ARM64]/"
case_ "runner group, inline"             fail "$EXPECTED" "s/^    runs-on: ubuntu-latest$/    runs-on: { group: local-ci }/"
case_ "runner group, multi-line"         fail "$EXPECTED" "" "$(printf '  grouped:\n    runs-on:\n      group: local-ci\n    steps:\n      - run: echo grouped')"
case_ "label list, multi-line"           fail "$EXPECTED" "" "$(printf '  listed:\n    runs-on:\n      - linux\n      - arm64\n    steps:\n      - run: echo listed')"
case_ "unevaluable expression"           fail "$EXPECTED" "s/^    runs-on: ubuntu-latest$/    runs-on: \${{ matrix.os }}/"
# Hosted forms that must keep passing.
case_ "hosted image, quoted and pinned"  pass "$EXPECTED" "s/^    runs-on: ubuntu-latest$/    runs-on: 'ubuntu-24.04'/"
case_ "hosted image, other case"         pass "$EXPECTED" "s/^    runs-on: ubuntu-latest$/    runs-on: Ubuntu-Latest/"
case_ "hosted arm image"                 pass "$EXPECTED" "s/^    runs-on: ubuntu-latest$/    runs-on: ubuntu-24.04-arm/"
case_ "hosted image as one-item list"    pass "$EXPECTED" "s/^    runs-on: ubuntu-latest$/    runs-on: [ ubuntu-latest ]/"
case_ "list mixing hosted and local"     fail "$EXPECTED" "s/^    runs-on: ubuntu-latest$/    runs-on: [ubuntu-latest, self-hosted]/"
case_ "unbalanced bracket"               fail "$EXPECTED" "s/^    runs-on: ubuntu-latest$/    runs-on: [ubuntu-latest/"
case_ "empty expected, nothing routed"   pass "" "/runs-on: \${{ vars.CI_RUNNER/s/.*/    runs-on: ubuntu-latest/"
# A custom label: it has to be passed, and the expression has to carry it.
LABEL=acme-ci case_ "custom label, passed"     pass "$EXPECTED" 's/"local-ci"/"acme-ci"/'
case_ "custom label, not passed"                fail "$EXPECTED" 's/"local-ci"/"acme-ci"/'
LABEL=acme-ci case_ "custom label, stale copy" fail "$EXPECTED"

# check <name> <want> <got>: a fixed expectation, for the print-only flags.
check() {
  if [ "$2" = "$3" ]; then
    echo "  ok   $1"; pass=$((pass + 1))
  else
    echo "  FAIL $1"; printf '       wanted: %s\n       got:    %s\n' "$2" "$3"; fail=$((fail + 1))
  fi
}

# --list names the jobs that carry the canonical expression, checks nothing
# else, and stays quiet otherwise: the output is for scripts to read.
mutated="$(mktemp -d)"
cp "${HERE}/base/"*.yml "$mutated/"
check "--list: the routed jobs of the clean base" "ci.yml:changes
ci.yml:checks" "$(python3 "$SCRIPT" --workflows-dir "${HERE}/base" --list)"
"${SED_INPLACE[@]}" -e "/^  checks:\$/,\$ s/ || 'ubuntu-latest' }}/ }}/" "$mutated/ci.yml"
got_rc=0
got="$(python3 "$SCRIPT" --workflows-dir "$mutated" --list 2>&1)" || got_rc=$?
check "--list: a drifted copy is not listed, and is not a failure" "ci.yml:changes|0" "$(echo "$got" | tr '\n' ' ' | sed 's/ *$//')|${got_rc}"
check "--list: a custom label lists only jobs on it" "ci.yml:changes
ci.yml:checks" "$(python3 "$SCRIPT" --workflows-dir "${HERE}/base" --label local-ci --list)"
check "--list: nothing for another label" "" "$(python3 "$SCRIPT" --workflows-dir "${HERE}/base" --label acme-ci --list)"
check "--list ignores --expected" "ci.yml:changes
ci.yml:checks" "$(python3 "$SCRIPT" --workflows-dir "${HERE}/base" --expected "ci.yml:docker" --list)"
rm -rf "$mutated"
if python3 "$SCRIPT" --workflows-dir /nonexistent --list >/dev/null 2>&1; then
  echo "  FAIL --list on a missing directory: wanted fail, got pass"; fail=$((fail + 1))
else
  echo "  ok   --list on a missing directory (fail)"; pass=$((pass + 1))
fi

# --print-expression is the expression the fixtures carry, for any label.
base_expr="$(sed -n 's/^    runs-on: \(\${{ vars.CI_RUNNER.*}}\)$/\1/p' "${HERE}/base/ci.yml" | head -1)"
check "--print-expression equals the fixture's copy" "$base_expr" "$(python3 "$SCRIPT" --print-expression)"
check "--print-expression carries the label and arch" "yes" \
  "$(python3 "$SCRIPT" --print-expression --label acme-ci --arch x64 | grep -c '\["self-hosted","linux","x64","acme-ci"\]' | sed 's/1/yes/')"
if python3 "$SCRIPT" --print-expression --label linux >/dev/null 2>&1; then
  echo "  FAIL --print-expression with a reserved label: wanted fail, got pass"; fail=$((fail + 1))
else
  echo "  ok   --print-expression with a reserved label (fail)"; pass=$((pass + 1))
fi

# A missing directory must fail, not pass vacuously.
if python3 "$SCRIPT" --workflows-dir /nonexistent --expected "" >/dev/null 2>&1; then
  echo "  FAIL missing workflows dir: wanted fail, got pass"; fail=$((fail + 1))
else
  echo "  ok   missing workflows dir (fail)"; pass=$((pass + 1))
fi

echo
echo "${pass} passed, ${fail} failed"
[ "$fail" -eq 0 ]
