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

# case <name> <want: pass|fail> <expected list> [sed expression]
case_() {
  local name="$1" want="$2" expected="$3" mutation="${4:-}"
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
  local got=pass
  python3 "$SCRIPT" --workflows-dir "$dir" --expected "$expected" >"$dir/out" 2>&1 || got=fail
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
case_ "bare self-hosted job"             fail "$EXPECTED" "s/^    runs-on: ubuntu-latest$/    runs-on: [self-hosted, linux, arm64]/"
case_ "label outside runs-on"            fail "$EXPECTED" "s/^      - run: echo docker$/      - run: echo i2dev-ci/"
case_ "opted-in job not in expected"     fail "ci.yml:changes"
case_ "expected job not opted in"        fail "$EXPECTED ci.yml:docker"
case_ "job id with trailing comment"     pass "$EXPECTED" "s/^  checks:$/  checks: # lint and test/"
case_ "empty expected, nothing routed"   pass "" "/runs-on: \${{ vars.CI_RUNNER/s/.*/    runs-on: ubuntu-latest/"

# A missing directory must fail, not pass vacuously.
if python3 "$SCRIPT" --workflows-dir /nonexistent --expected "" >/dev/null 2>&1; then
  echo "  FAIL missing workflows dir: wanted fail, got pass"; fail=$((fail + 1))
else
  echo "  ok   missing workflows dir (fail)"; pass=$((pass + 1))
fi

echo
echo "${pass} passed, ${fail} failed"
[ "$fail" -eq 0 ]
