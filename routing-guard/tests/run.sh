#!/usr/bin/env bash
# Fixture suite for routing_guard.py. Each case copies base/ into a scratch
# workflows dir, applies one mutation, and asserts the exit status. The
# mutations are the ways a hand-edited copy of the expression actually drifts.
#
# Run:  bash routing-guard/tests/run.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${HERE}/../routing_guard.py"
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
  python3 "$SCRIPT" --workflows-dir "$dir" --jobs "$expected" ${LABEL:+--label "$LABEL"} >"$dir/out" 2>&1 || got=fail
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
case_ "label in a step, not routing"     pass "$EXPECTED" "s/^      - run: echo docker$/      - name: Verify self-hosted homefield-ci routing/"
case_ "opted-in job not in expected"     fail "ci.yml:changes"
case_ "expected job not opted in"        fail "$EXPECTED ci.yml:docker"
case_ "job id with trailing comment"     pass "$EXPECTED" "s/^  checks:$/  checks: # lint and test/"
case_ "quoted job id, not expected"      fail "ci.yml:changes" "s/^  checks:$/  \"checks\":/"
case_ "quoted job id, expected"          pass "$EXPECTED" "s/^  checks:$/  'checks':/"
# Ways to reach the runner without writing `self-hosted` or the label as-is.
# GitHub matches labels case-insensitively and by superset, and the runner is
# in the homefield-ci group, so each of these would run unguarded on the VM.
case_ "Self-Hosted in other case"        fail "$EXPECTED" "s/^    runs-on: ubuntu-latest$/    runs-on: Self-Hosted/"
case_ "label in other case"              fail "$EXPECTED" "s/^    runs-on: ubuntu-latest$/    runs-on: [self-hosted, HOMEFIELD-CI]/"
case_ "default labels only"              fail "$EXPECTED" "s/^    runs-on: ubuntu-latest$/    runs-on: [linux, ARM64]/"
case_ "runner group, inline"             fail "$EXPECTED" "s/^    runs-on: ubuntu-latest$/    runs-on: { group: homefield-ci }/"
case_ "runner group, multi-line"         fail "$EXPECTED" "" "$(printf '  grouped:\n    runs-on:\n      group: homefield-ci\n    steps:\n      - run: echo grouped')"
case_ "label list, multi-line"           fail "$EXPECTED" "" "$(printf '  listed:\n    runs-on:\n      - linux\n      - arm64\n    steps:\n      - run: echo listed')"
case_ "unevaluable expression"           fail "$EXPECTED" "s/^    runs-on: ubuntu-latest$/    runs-on: \${{ matrix.os }}/"
# Valid YAML that says "runs-on" another way: the line scan cannot see it, so
# it fails and says how to write it plainly (GHSA-4795-jpw2-47v2).
case_ "quoted runs-on key"               fail "$EXPECTED" "" "$(printf '  unsafe:\n    "runs-on": self-hosted\n    steps:\n      - run: echo unsafe')"
case_ "single-quoted runs-on key"        fail "$EXPECTED" "" "$(printf "  unsafe:\n    'runs-on': self-hosted\n    steps:\n      - run: echo unsafe")"
case_ "job written as a {...} mapping"   fail "$EXPECTED" "" "  unsafe: {runs-on: self-hosted, steps: [{run: echo unsafe}]}"
case_ "quoted key in a {...} job"        fail "$EXPECTED" "" '  unsafe: {"runs-on": Self-Hosted}'
case_ "{...} mapping on the next line"   fail "$EXPECTED" "" "$(printf '  unsafe:\n    {runs-on: self-hosted}')"
case_ "runs-on through a merge key"      fail "$EXPECTED" "" "$(printf '  unsafe:\n    <<: {runs-on: self-hosted}\n    steps: []')"
case_ "runs-on as a ? complex key"       fail "$EXPECTED" "" "$(printf '  unsafe:\n    ? runs-on\n    : self-hosted')"
case_ "space before the colon"           fail "$EXPECTED" "" "$(printf '  unsafe:\n    runs-on : self-hosted')"
case_ "key spelled with an escape"       fail "$EXPECTED" "" "$(printf '  unsafe:\n    "\\x72uns-on": self-hosted')"
case_ "job id as an alias"               fail "$EXPECTED" "" "  unsafe: *shared"
case_ "jobs: given as one {...} line"    fail "$EXPECTED" "" "s/^jobs:\$/jobs: {a: {runs-on: self-hosted}}/"
case_ "spaced top-level jobs key"        fail "$EXPECTED" "" "s/^jobs:\$/jobs :/"
case_ "quoted key left open on its line"  fail "$EXPECTED" "" "$(printf '  unsafe:\n    "runs-\\\n    on": self-hosted')"
case_ "? key split by a trailing \\"     fail "$EXPECTED" "" "$(printf '  unsafe:\n    ? "runs-\\\n      on"\n    : self-hosted')"
case_ "single-quoted key left open"     fail "$EXPECTED" "" "$(printf "  unsafe:\n    'runs-\n    on': self-hosted")"
# Plain forms around them that must keep passing.
# Text under a block scalar is not YAML syntax: a script line may start with ?, a
# bracket or an open quote (regression in v0.2.0, found on real workflows).
case_ "script lines that look like syntax" pass "$EXPECTED" "" "$(printf '  scripts:\n    runs-on: ubuntu-latest\n    steps:\n      - run: |\n          ? what\n          "an open quote\n          { runs-on; }\n          cat <<EOF\n          "runs-on": x\n          EOF\n      - name: after')"
case_ "folded script, the same"          pass "$EXPECTED" "" "$(printf '  scripts:\n    runs-on: ubuntu-latest\n    steps:\n      - name: x\n        run: >-\n          ? what\n          "an open quote\n      - run: echo done')"
case_ "list item scalar, the same"       pass "$EXPECTED" "" "$(printf '  scripts:\n    runs-on: ubuntu-latest\n    steps:\n      - |\n        ? what\n        "open')"
case_ "split key right after a script"   fail "$EXPECTED" "" "$(printf '  scripts:\n    runs-on: ubuntu-latest\n    steps:\n      - run: |\n          echo hi\n    ? "runs-\\\n      on"\n    : self-hosted')"
case_ "key at the scalar key indent"     fail "$EXPECTED" "" "$(printf '  scripts:\n    steps:\n      - run: |\n          echo hi\n        "runs-on": self-hosted')"
# Plain text that merely mentions the field must keep passing.
case_ "a step script that quotes runs-on" pass "$EXPECTED" "s/^      - run: echo docker\$/      - run: echo \"runs-on\"/"
case_ "a step script with {runs-on: x}"  pass "$EXPECTED" "s/^      - run: echo docker\$/      - run: echo '{runs-on: self-hosted}'/"
case_ "a block script that quotes it"    pass "$EXPECTED" "" "$(printf '  doc:\n    runs-on: ubuntu-latest\n    steps:\n      - run: |\n          echo "runs-on"\n          echo "a, runs-on: x"')"
case_ "trailing comment after jobs:"     pass "$EXPECTED" "s/^jobs:\$/jobs: # the jobs/"
case_ "document start marker"            pass "$EXPECTED" "1s/^/---\\n/"
case_ "plain flow data elsewhere"        pass "$EXPECTED" "s/^      - run: echo docker\$/      - run: echo docker\\n        env: {A: b}/"
# Hosted forms that must keep passing.
case_ "hosted image, quoted and pinned"  pass "$EXPECTED" "s/^    runs-on: ubuntu-latest$/    runs-on: 'ubuntu-24.04'/"
case_ "hosted image, other case"         pass "$EXPECTED" "s/^    runs-on: ubuntu-latest$/    runs-on: Ubuntu-Latest/"
case_ "hosted arm image"                 pass "$EXPECTED" "s/^    runs-on: ubuntu-latest$/    runs-on: ubuntu-24.04-arm/"
case_ "hosted image as one-item list"    pass "$EXPECTED" "s/^    runs-on: ubuntu-latest$/    runs-on: [ ubuntu-latest ]/"
case_ "list mixing hosted and local"     fail "$EXPECTED" "s/^    runs-on: ubuntu-latest$/    runs-on: [ubuntu-latest, self-hosted]/"
case_ "unbalanced bracket"               fail "$EXPECTED" "s/^    runs-on: ubuntu-latest$/    runs-on: [ubuntu-latest/"
case_ "empty expected, nothing routed"   pass "" "/runs-on: \${{ vars.CI_RUNNER/s/.*/    runs-on: ubuntu-latest/"
# A custom label: it has to be passed, and the expression has to carry it.
LABEL=acme-ci case_ "custom label, passed"     pass "$EXPECTED" 's/"homefield-ci"/"acme-ci"/'
case_ "custom label, not passed"                fail "$EXPECTED" 's/"homefield-ci"/"acme-ci"/'
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
ci.yml:checks" "$(python3 "$SCRIPT" --workflows-dir "${HERE}/base" --label homefield-ci --list)"
check "--list: nothing for another label" "" "$(python3 "$SCRIPT" --workflows-dir "${HERE}/base" --label acme-ci --list)"
check "--list ignores --jobs" "ci.yml:changes
ci.yml:checks" "$(python3 "$SCRIPT" --workflows-dir "${HERE}/base" --jobs "ci.yml:docker" --list)"
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

# ── Options: events, dependabot, fallback ─────────────────────────────────
# The default expression is today's, byte for byte: workflows already carrying
# it must keep passing. Hard-coded, so a change to the builder cannot change
# the test along with it.
# shellcheck disable=SC2016  # GitHub expression text, not shell
TODAY='${{ vars.CI_RUNNER == '"'local'"' && github.event_name == '"'pull_request'"' && github.actor != '"'dependabot[bot]'"' && !startsWith(github.head_ref, '"'dependabot/'"') && github.event.pull_request.head.repo.full_name == github.repository && fromJSON('"'"'["self-hosted","linux","arm64","homefield-ci"]'"'"') || '"'ubuntu-latest'"' }}'
check "--print-expression, no options, is today's string byte for byte" "$TODAY" "$(python3 "$SCRIPT" --print-expression)"
check "--print-expression, the options spelled as defaults, is the same" "$TODAY" \
  "$(python3 "$SCRIPT" --print-expression --events pull_request --dependabot hosted --fallback ubuntu-latest)"
check "the fixture's copy is today's string" "$TODAY" "$base_expr"

LABELS='fromJSON('"'"'["self-hosted","linux","arm64","homefield-ci"]'"'"')'
DEP="github.actor != 'dependabot[bot]' && !startsWith(github.head_ref, 'dependabot/')"
FORKPR='github.event.pull_request.head.repo.full_name == github.repository'
FORKANY="(github.event_name != 'pull_request' || ${FORKPR})"
printed() { python3 "$SCRIPT" --print-expression "$@"; }
check "events push: one clause, and the fork clause lets non-PR events through" \
  "\${{ vars.CI_RUNNER == 'local' && github.event_name == 'push' && ${DEP} && ${FORKANY} && ${LABELS} || 'ubuntu-latest' }}" \
  "$(printed --events push)"
check "events pull_request and push: parenthesised, in canonical order" \
  "\${{ vars.CI_RUNNER == 'local' && (github.event_name == 'pull_request' || github.event_name == 'push') && ${DEP} && ${FORKANY} && ${LABELS} || 'ubuntu-latest' }}" \
  "$(printed --events push,pull_request)"
check "events: order, duplicates and separators do not matter" "$(printed --events push,pull_request)" \
  "$(printed --events "pull_request push, pull_request
push")"
check "events: all four, in canonical order" \
  "\${{ vars.CI_RUNNER == 'local' && (github.event_name == 'pull_request' || github.event_name == 'push' || github.event_name == 'workflow_dispatch' || github.event_name == 'schedule') && ${DEP} && ${FORKANY} && ${LABELS} || 'ubuntu-latest' }}" \
  "$(printed --events schedule,workflow_dispatch,push,pull_request)"
check "events pull_request alone keeps the bare fork clause" "$TODAY" "$(printed --events pull_request)"
check "dependabot local drops both clauses" \
  "\${{ vars.CI_RUNNER == 'local' && github.event_name == 'pull_request' && ${FORKPR} && ${LABELS} || 'ubuntu-latest' }}" \
  "$(printed --dependabot local)"
check "fallback is the last leg" \
  "\${{ vars.CI_RUNNER == 'local' && github.event_name == 'pull_request' && ${DEP} && ${FORKPR} && ${LABELS} || 'ubuntu-24.04-arm' }}" \
  "$(printed --fallback ubuntu-24.04-arm)"
check "push + dependabot local + fallback ubuntu-24.04-arm" \
  "\${{ vars.CI_RUNNER == 'local' && github.event_name == 'push' && ${FORKANY} && ${LABELS} || 'ubuntu-24.04-arm' }}" \
  "$(printed --events push --dependabot local --fallback ubuntu-24.04-arm)"
check "options with a label and arch together" \
  "\${{ vars.CI_RUNNER == 'local' && github.event_name == 'push' && ${DEP} && ${FORKANY} && fromJSON('[\"self-hosted\",\"linux\",\"x64\",\"acme-ci\"]') || 'ubuntu-latest' }}" \
  "$(printed --events push --label acme-ci --arch x64)"

# invalid <name> <message fragment> <flags...>: --print-expression and a check
# both refuse, with the reason in the output.
invalid() {
  local name="$1" fragment="$2" out rc=0
  shift 2
  out="$(python3 "$SCRIPT" --print-expression "$@" 2>&1)" || rc=$?
  if [ "$rc" -ne 0 ] && case "$out" in *"$fragment"*) true ;; *) false ;; esac; then
    echo "  ok   ${name} (refused)"; pass=$((pass + 1))
  else
    echo "  FAIL ${name}: wanted a refusal naming '${fragment}', got status ${rc}: ${out}"; fail=$((fail + 1))
  fi
  rc=0
  python3 "$SCRIPT" --workflows-dir "${HERE}/base" --jobs "$EXPECTED" "$@" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "  ok   ${name}, as a check (refused)"; pass=$((pass + 1))
  else
    echo "  FAIL ${name}, as a check: wanted a refusal, got pass"; fail=$((fail + 1))
  fi
}
invalid "events pull_request_target" "pull_request_target is refused" --events pull_request_target
invalid "events pull_request_target among others" "secrets on code from forks" --events "pull_request,pull_request_target"
invalid "events merge_group" "merge_group is refused" --events merge_group
invalid "events merge_group among others" "pull request from a fork" --events "pull_request,merge_group"
invalid "events empty" "name at least one" --events ""
invalid "events only separators" "name at least one" --events " , "
invalid "events an unknown name" "'issues' is not one of" --events issues
invalid "events in another case" "'Push' is not one of" --events Push
invalid "dependabot an unknown value" "must be hosted or local" --dependabot maybe
invalid "dependabot empty" "must be hosted or local" --dependabot ""
invalid "dependabot in another case" "must be hosted or local" --dependabot Local
invalid "fallback self-hosted" "bare GitHub-hosted image name" --fallback self-hosted
invalid "fallback the routing label" "bare GitHub-hosted image name" --fallback homefield-ci
invalid "fallback a list" "bare GitHub-hosted image name" --fallback "[ubuntu-latest]"
invalid "fallback quoted" "bare GitHub-hosted image name" --fallback "'ubuntu-latest'"
invalid "fallback empty" "bare GitHub-hosted image name" --fallback ""
invalid "fallback with a space" "bare GitHub-hosted image name" --fallback "ubuntu-latest, self-hosted"
invalid "fallback with a trailing newline" "bare GitHub-hosted image name" --fallback "ubuntu-latest
"
check "fallback accepts other hosted images, in any case" "yes" \
  "$(printed --fallback Windows-2022 >/dev/null && printed --fallback macos-15 >/dev/null && echo yes)"

# opt_case <name> <want> <flags the workflow's expression was built with> --
# <flags the check runs with>: a workflow whose job carries one expression,
# checked with another set of options.
opt_case() {
  local name="$1" want="$2" built="$3" dir got=pass
  shift 4
  dir="$(mktemp -d)"
  # shellcheck disable=SC2086  # $built is a few flags, no spaces within a value
  printf 'on: [pull_request]\njobs:\n  changes:\n    runs-on: %s\n    steps:\n      - run: echo changes\n' \
    "$(python3 "$SCRIPT" --print-expression $built)" >"$dir/ci.yml"
  python3 "$SCRIPT" --workflows-dir "$dir" --jobs "ci.yml:changes" "$@" >"$dir/out" 2>&1 || got=fail
  if [ "$got" = "$want" ]; then
    echo "  ok   ${name} (${got})"; pass=$((pass + 1))
  else
    echo "  FAIL ${name}: wanted ${want}, got ${got}"; sed 's/^/       /' "$dir/out"; fail=$((fail + 1))
  fi
  rm -rf "$dir"
}
opt_case "events push: matching copy passes"            pass "--events push" -- --events push
opt_case "events push: the default copy is a mismatch"  fail "" -- --events push
opt_case "events push: the push copy fails the default" fail "--events push" --
opt_case "events pull_request,push: matching copy passes" pass "--events pull_request,push" -- --events "push pull_request"
opt_case "events pull_request,push: a push-only copy fails" fail "--events push" -- --events pull_request,push
opt_case "dependabot local: matching copy passes"       pass "--dependabot local" -- --dependabot local
opt_case "dependabot local: the default copy fails"     fail "" -- --dependabot local
opt_case "dependabot local: the local copy fails the default" fail "--dependabot local" --
opt_case "fallback: matching copy passes"               pass "--fallback ubuntu-24.04-arm" -- --fallback ubuntu-24.04-arm
opt_case "fallback: the default copy fails"             fail "" -- --fallback ubuntu-24.04-arm
opt_case "combination: matching copy passes"            pass "--events push --dependabot local --fallback ubuntu-24.04-arm" -- --events push --dependabot local --fallback ubuntu-24.04-arm
opt_case "combination: one option off fails"            fail "--events push --dependabot local --fallback ubuntu-24.04-arm" -- --events push --dependabot local
opt_case "a custom label with options"                  pass "--label acme-ci --events push" -- --label acme-ci --events push

# --list honours the options too.
pushdir="$(mktemp -d)"
printf 'on: [push]\njobs:\n  deploy:\n    runs-on: %s\n    steps:\n      - run: echo deploy\n' "$(printed --events push)" >"$pushdir/ci.yml"
check "--list: a push-routed job is listed with --events push" "ci.yml:deploy" "$(python3 "$SCRIPT" --workflows-dir "$pushdir" --events push --list)"
check "--list: and not under the defaults" "" "$(python3 "$SCRIPT" --workflows-dir "$pushdir" --list)"
rm -rf "$pushdir"

# The self-check: a weakened canonical_expression must fail it, with nothing
# else wrong. An empty workflows directory and no expected jobs leave the
# self-check as the only thing that can fail. $WEAKEN is a python expression
# over the real expression `x`.
selfcheck() { # <flags...>
  local empty rc=0
  empty="$(mktemp -d)"
  python3 -c '
import os, sys
sys.path.insert(0, sys.argv[1])
import routing_guard as g
weaken = os.environ.get("WEAKEN")
if weaken:
    real = g.canonical_expression
    g.canonical_expression = lambda *a, **k: eval(weaken, {}, {"x": real(*a, **k)})
sys.argv = ["routing_guard.py", "--workflows-dir", sys.argv[2], "--jobs", ""] + sys.argv[3:]
sys.exit(g.main())
' "${HERE}/.." "$empty" "$@" >/dev/null 2>&1 || rc=$?
  rm -rf "$empty"
  echo "$rc"
}
check "self-check: the intact expression passes" "0" "$(selfcheck)"
check "self-check: the intact expression passes with options" "0" "$(selfcheck --events push,schedule --dependabot local --fallback ubuntu-24.04-arm)"
check "self-check: a missing hosted fallback fails" "1" "$(WEAKEN="x.replace(\" || 'ubuntu-latest'\", '')" selfcheck)"
check "self-check: a missing switch fails" "1" "$(WEAKEN="x.replace(\"vars.CI_RUNNER == 'local' && \", '')" selfcheck)"
check "self-check: a missing event clause fails" "1" "$(WEAKEN="x.replace(\"github.event_name == 'pull_request' && \", '')" selfcheck)"
check "self-check: a missing fork clause fails" "1" "$(WEAKEN="x.replace(' && github.event.pull_request.head.repo.full_name == github.repository', '')" selfcheck)"
check "self-check: a missing Dependabot clause fails when hosted" "1" "$(WEAKEN="x.replace(\"github.actor != 'dependabot[bot]' && \", '')" selfcheck)"
check "self-check: a fork clause that skips non-PR events fails the push form" "1" \
  "$(WEAKEN="x.replace(\"(github.event_name != 'pull_request' || \", '(').replace('repository)', 'repository')" selfcheck --events push)"
check "self-check: a fallback that is not the chosen one fails" "1" "$(WEAKEN="x.replace('ubuntu-24.04-arm', 'ubuntu-latest')" selfcheck --fallback ubuntu-24.04-arm)"
check "self-check: Dependabot clauses are not required when local" "0" "$(selfcheck --dependabot local)"

# A key named `runs-on:` outside `jobs:` — a workflow_dispatch input, say — is
# not routing and must not fail the check (it would read as an empty, hence
# multi-line, runs-on).
dispatch="$(mktemp -d)"
printf '%s\n' \
  'on:' \
  '  workflow_dispatch:' \
  '    inputs:' \
  '      runs-on:' \
  '        description: where to run' \
  '        default: hosted' \
  'jobs:' \
  '  build:' \
  '    runs-on: ubuntu-latest' \
  '    steps:' \
  '      - run: echo build' >"$dispatch/ci.yml"
if python3 "$SCRIPT" --workflows-dir "$dispatch" --jobs "" >/dev/null 2>&1; then
  echo "  ok   a runs-on key under on: is not routing (pass)"; pass=$((pass + 1))
else
  echo "  FAIL a runs-on key under on: is not routing: wanted pass, got fail"; fail=$((fail + 1))
fi
rm -rf "$dispatch"

# A workflow indented four spaces: --list and the expected list must still
# name its job, not "None".
indent="$(mktemp -d)"
printf '%s\n' \
  'on: [pull_request]' \
  'jobs:' \
  '    changes:' \
  "        runs-on: ${base_expr}" \
  '        steps:' \
  '            - run: echo changes' >"$indent/ci.yml"
check "a four-space workflow: the job is attributed" "ci.yml:changes" \
  "$(python3 "$SCRIPT" --workflows-dir "$indent" --list)"
if python3 "$SCRIPT" --workflows-dir "$indent" --jobs "ci.yml:changes" >/dev/null 2>&1; then
  echo "  ok   a four-space workflow checks clean (pass)"; pass=$((pass + 1))
else
  echo "  FAIL a four-space workflow checks clean: wanted pass, got fail"; fail=$((fail + 1))
fi
rm -rf "$indent"

# A quoted top-level `jobs:` key (`"jobs":`) is valid YAML. If the parser
# missed it, every runs-on in the file would go unchecked — with an empty
# expected list, even a bare `runs-on: self-hosted` would pass.
quoted="$(mktemp -d)"
printf '%s\n' \
  'on: [pull_request]' \
  '"jobs":' \
  '  build:' \
  "    runs-on: ${base_expr}" \
  '    steps:' \
  '      - run: echo build' >"$quoted/ci.yml"
check "a quoted jobs key: the job is attributed" "ci.yml:build" \
  "$(python3 "$SCRIPT" --workflows-dir "$quoted" --list)"
if python3 "$SCRIPT" --workflows-dir "$quoted" --jobs "ci.yml:build" >/dev/null 2>&1; then
  echo "  ok   a quoted jobs key checks clean (pass)"; pass=$((pass + 1))
else
  echo "  FAIL a quoted jobs key checks clean: wanted pass, got fail"; fail=$((fail + 1))
fi
rm -rf "$quoted"

quoted="$(mktemp -d)"
printf '%s\n' \
  'on: [pull_request]' \
  '"jobs":' \
  '  build:' \
  '    runs-on: self-hosted' \
  '    steps:' \
  '      - run: echo build' >"$quoted/ci.yml"
if python3 "$SCRIPT" --workflows-dir "$quoted" --jobs "" >/dev/null 2>&1; then
  echo "  FAIL a bare self-hosted under a quoted jobs key: wanted fail, got pass"; fail=$((fail + 1))
else
  echo "  ok   a bare self-hosted under a quoted jobs key fails (pass)"; pass=$((pass + 1))
fi
rm -rf "$quoted"

# A missing directory must fail, not pass vacuously.
if python3 "$SCRIPT" --workflows-dir /nonexistent --jobs "" >/dev/null 2>&1; then
  echo "  FAIL missing workflows dir: wanted fail, got pass"; fail=$((fail + 1))
else
  echo "  ok   missing workflows dir (fail)"; pass=$((pass + 1))
fi

echo
echo "${pass} passed, ${fail} failed"
[ "$fail" -eq 0 ]
