#!/usr/bin/env bash
# `bin/homefield adopt` and its helpers: the repository checks, the runner
# group access, the routing check on downloaded workflows, the cache-key
# warnings and the switch. bin/homefield is sourced (HOMEFIELD_SOURCE_ONLY=1)
# with a stub gh that records its calls and answers from files, including a
# fixture .github/workflows served through the contents API. Nothing reaches
# GitHub or a VM, and no write is ever real.
#
# Run:  bash tests/adopt.sh
set -uo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

has() { case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac; }
nonzero() { [ "$1" -ne 0 ] && echo nonzero || echo "$1"; }
# before <text> <a> <b>: yes when line a comes before line b (both must be there).
before() {
  local la lb
  la="$(printf '%s\n' "$1" | grep -n -m1 -F -e "$2" | cut -d: -f1)"
  lb="$(printf '%s\n' "$1" | grep -n -m1 -F -e "$3" | cut -d: -f1)"
  if [ -n "$la" ] && [ -n "$lb" ] && [ "$la" -lt "$lb" ]; then echo yes; else echo "no ($la, $lb)"; fi
}

stubs="$work/stubs"
calls="$work/calls"
mkdir -p "$stubs" "$work/tmp"
# The stub answers like gh with --jq applied. GH_WF is the directory served as
# .github/workflows (absent: a 404), GH_REPO the row for repos/<owner>/<repo>.
cat >"$work/gh" <<'EOF'
#!/bin/sh
echo "gh $*" >>"$CALLS"
case "$*" in
  "variable get CI_RUNNER"*)
    if [ -n "${GH_CI_RUNNER:-}" ]; then echo "$GH_CI_RUNNER"; else echo "variable not found" >&2; exit 1; fi
    ;;
  "variable set"*) ;;
  *"-X PUT"*)
    if [ -n "${GH_PUT_FAIL:-}" ]; then echo "gh: HTTP 403" >&2; exit 1; fi
    ;;
  *"/contents/.github/workflows/"*)
    for a in "$@"; do case "$a" in repos/*/contents/.github/workflows/*) name="${a##*/}" ;; esac; done
    name="$(printf '%s' "$name" | sed 's/%20/ /g')"
    cat "$GH_WF/$name"
    ;;
  *"/contents/.github/workflows"*)
    if [ ! -d "${GH_WF:-/nonexistent}" ]; then echo "gh: Not Found (HTTP 404)" >&2; exit 1; fi
    if [ -n "${GH_WF_FAIL:-}" ]; then echo "gh: Server Error (HTTP 500)" >&2; exit 1; fi
    for f in "$GH_WF"/*; do if [ -f "$f" ]; then basename "$f"; fi; done
    ;;
  *"runner-groups/"*"/repositories?"*)
    if [ -n "${GH_MEMBERS_FAIL:-}" ]; then echo "gh: HTTP 500" >&2; exit 1; fi
    cat "$GH_MEMBERS"
    ;;
  *runner-groups*)
    if [ -n "${GH_LIST_FAIL:-}" ]; then echo '{"message":"Must have admin rights"}'; echo "gh: HTTP 403" >&2; exit 1; fi
    cat "$GH_GROUPS"
    ;;
  "api repos/"*)
    if [ -n "${GH_REPO_FAIL:-}" ]; then echo "gh: Not Found (HTTP 404)" >&2; exit 1; fi
    printf '%s\n' "${GH_REPO:-true	555	main	Organization}"
    ;;
esac
EOF
chmod +x "$work/gh"
for t in awk basename cat dirname git grep head ls mkdir mktemp rm sed sleep tr wc; do ln -s "$(command -v "$t")" "$stubs/$t"; done
# The interpreter itself, not whatever `python3` resolves to: a pyenv (or asdf)
# shim is a script that needs pyenv and its tools on PATH, which the isolated
# PATH of these tests does not have.
python_exe="$(python3 -c 'import sys; print(sys.executable)' 2>/dev/null)"
if [ ! -x "$python_exe" ]; then
  echo "tests: no usable python3 on PATH (found: $(command -v python3 || echo none)); put a real interpreter first" >&2
  exit 1
fi
# A script, so that a test can make `routing_guard.py --list` fail (PY_LIST_FAIL).
cat >"$stubs/python3" <<SHIM
#!/bin/sh
if [ -n "\${PY_LIST_FAIL:-}" ]; then
  case " \$* " in *routing_guard.py*" --list "*) echo "python3: stub crash" >&2; exit 2 ;; esac
fi
exec "$python_exe" "\$@"
SHIM
chmod +x "$stubs/python3"
cp "$work/gh" "$stubs/gh"

# The group rows are name, visibility, public allowed, id.
printf 'Default\tall\tfalse\t1\nhomefield-ci\tselected\tfalse\t42\n' >"$work/groups-selected"
printf 'Default\tall\tfalse\t1\nHomeField-CI\tselected\tfalse\t42\n' >"$work/groups-case"
printf 'Default\tall\tfalse\t1\nhomefield-ci\tall\tfalse\t42\n' >"$work/groups-all"
printf 'Default\tall\tfalse\t1\nhomefield-ci\tprivate\tfalse\t42\n' >"$work/groups-private"
printf 'Default\tall\tfalse\t1\n' >"$work/groups-none"
printf 'Default\tall\tfalse\t1\nhomefield-ci\tselected\ttrue\t42\n' >"$work/groups-selected-public"
printf 'Default\tall\tfalse\t1\nhomefield-ci\tall\ttrue\t42\n' >"$work/groups-all-public"
printf '100\n200\n' >"$work/members-other"
printf '100\n555\n200\n' >"$work/members-with"
: >"$work/members-empty"

# ── Workflow fixtures ──────────────────────────────────────────────────────
expr="$(python3 "$ROOT/routing-guard/routing_guard.py" --print-expression)"
expr_acme="$(python3 "$ROOT/routing-guard/routing_guard.py" --print-expression --label acme-ci)"
expr_push="$(python3 "$ROOT/routing-guard/routing_guard.py" --print-expression --events push)"
expr_combo="$(python3 "$ROOT/routing-guard/routing_guard.py" --print-expression --events push,schedule --dependabot local --fallback ubuntu-24.04-arm)"
expr_x64="$(python3 "$ROOT/routing-guard/routing_guard.py" --print-expression --arch x64)"

# emit_job <id> <runs-on> [extra step lines...]
emit_job() {
  local id="$1" runs="$2" line
  shift 2
  printf '  %s:\n    runs-on: %s\n    steps:\n      - uses: actions/checkout@v5\n' "$id" "$runs"
  for line in "$@"; do printf '%s\n' "$line"; done
}
header() { printf 'name: CI\non: [pull_request]\njobs:\n'; }
# guard <job entries>  or guard_label <label> <block lines>
guard() { guard_uses i2Dev-com/homefield/routing-guard@v0.3.0 "$@"; }
guard_uses() {
  local uses="$1" e
  shift
  printf '      - name: Routing guard\n        uses: %s\n        with:\n          jobs: |\n' "$uses"
  for e in "$@"; do printf '            %s\n' "$e"; done
}
guard_label() {
  local label="$1"
  shift
  guard "$@"
  printf '          label: %s' "$label"
}
# guard_opts <job entry> <with: line>...: a guard step with more `with:` keys.
guard_opts() {
  local sep=""
  guard "$1"
  shift
  for line in "$@"; do
    printf '%s          %s' "$sep" "$line"
    sep=$'\n'
  done
}
# GitHub expression text, written with the $ escaped so that it is not shell.
os_key="\${{ runner.os }}"
arch_key="\${{ runner.arch }}"
hash_key="\${{ hashFiles('package-lock.json') }}"
cache_step() {
  printf '      - uses: actions/cache@v5\n        with:\n          path: ~/.npm\n          key: %s\n' "$1"
}

mkdir -p "$work/wf-ready" "$work/wf-noguard" "$work/wf-mismatch" "$work/wf-norouted" "$work/wf-label" "$work/wf-cache" "$work/wf-twoguards"
{
  header
  emit_job lint "$expr" "$(guard ci.yml:lint ci.yml:test)" "$(cache_step "${os_key}-${arch_key}-npm-${hash_key}")"
  emit_job test "$expr"
  emit_job build ubuntu-latest
} >"$work/wf-ready/ci.yml"
{ header; emit_job deploy ubuntu-latest; } >"$work/wf-ready/my flow.yaml"
echo "workflows" >"$work/wf-ready/README.md"
mkdir -p "$work/wf-ready/subdir"

{ header; emit_job lint "$expr"; emit_job test "$expr"; } >"$work/wf-noguard/ci.yml"
{
  header
  emit_job lint "$expr" "$(guard ci.yml:lint)"
  emit_job test "$expr"
} >"$work/wf-mismatch/ci.yml"
{
  header
  emit_job lint ubuntu-latest "$(printf '      - name: Routing guard\n        uses: i2Dev-com/homefield/routing-guard@v0.3.0\n        with:\n          jobs: '"''"'')"
} >"$work/wf-norouted/ci.yml"
{
  header
  emit_job lint "$expr_acme" "$(guard_label acme-ci ci.yml:lint)"
} >"$work/wf-label/ci.yml"
{
  header
  emit_job lint "$expr" "$(guard ci.yml:lint)" \
    "$(cache_step "${os_key}-npm-${hash_key}")" \
    "$(printf '          restore-keys: |\n            %s\n            %s' "${os_key}-npm-" "${os_key}-${arch_key}-npm-")"
} >"$work/wf-cache/ci.yml"
cache_line_key="$(grep -nF "key: ${os_key}-npm" "$work/wf-cache/ci.yml" | head -1 | cut -d: -f1)"
cache_line_restore="$(grep -nxF "            ${os_key}-npm-" "$work/wf-cache/ci.yml" | head -1 | cut -d: -f1)"
# A workflow with no routed job (a nightly that stays hosted): its keys are
# not the routed jobs' concern, so they are not reported once jobs are routed.
{ header; emit_job e2e ubuntu-latest "$(cache_step "${os_key}-pw-${hash_key}")"; } >"$work/wf-cache/nightly.yml"
# Two routing-guard steps: a stale one on the default label (its check fails
# against jobs routed on another label) and a passing one on that other label.
# The routed jobs count under either step, and the passing label is the one to
# advise with.
{
  header
  emit_job lint "$expr_acme" "$(guard ci.yml:lint)"
  emit_job test "$expr_acme" "$(guard_label acme-ci ci.yml:lint ci.yml:test)"
} >"$work/wf-twoguards/ci.yml"
# Guards with options: the routed jobs carry the expression for them.
expr_typo="$(python3 "$ROOT/routing-guard/routing_guard.py" --print-expression --fallback ubuntu-lates)"
mkdir -p "$work/wf-push" "$work/wf-combo" "$work/wf-prt" "$work/wf-typo"
{ header; emit_job lint "$expr_push" "$(guard_opts ci.yml:lint 'events: push')"; } >"$work/wf-push/ci.yml"
{
  header
  emit_job lint "$expr_combo" "$(guard_opts ci.yml:lint 'events: |' '  push' '  schedule' 'dependabot: local' 'fallback: ubuntu-24.04-arm')"
} >"$work/wf-combo/ci.yml"
{ header; emit_job lint "$expr" "$(guard_opts ci.yml:lint 'events: pull_request_target')"; } >"$work/wf-prt/ci.yml"
{ header; emit_job lint "$expr_typo" "$(guard_opts ci.yml:lint 'fallback: ubuntu-lates')"; } >"$work/wf-typo/ci.yml"
# The guard step's arch: adopt refuses anything but arm64, the VM it sets up.
mkdir -p "$work/wf-arch-x64" "$work/wf-arch-arm64" "$work/wf-arch-amd64"
{ header; emit_job lint "$expr_x64" "$(guard_opts ci.yml:lint 'arch: x64')"; } >"$work/wf-arch-x64/ci.yml"
{ header; emit_job lint "$expr" "$(guard_opts ci.yml:lint 'arch: arm64')"; } >"$work/wf-arch-arm64/ci.yml"
{ header; emit_job lint "$expr" "$(guard_opts ci.yml:lint 'arch: amd64')"; } >"$work/wf-arch-amd64/ci.yml"

# Fixtures for what makes a step a guard: the action it uses, and whether its
# workflow runs on pull requests. wf_guard <dir> <on-line> <uses> writes a
# ci.yml with the given `on:` line verbatim, one routed job and a guard step
# that uses <uses>.
wf_guard() {
  mkdir -p "$work/$1"
  {
    printf 'name: CI\n%s\njobs:\n' "$2"
    emit_job lint "$expr" "$(guard_uses "$3" ci.yml:lint)"
  } >"$work/$1/ci.yml"
}
action="i2Dev-com/homefield/routing-guard@v0.3.0"
sha40="0123456789abcdef0123456789abcdef01234567"
wf_guard wf-src-other 'on: [pull_request]' other-org/homefield/routing-guard@v0.3.0
wf_guard wf-src-v1 'on: [pull_request]' i2Dev-com/homefield/routing-guard@v1
wf_guard wf-src-v3 'on: [pull_request]' i2Dev-com/homefield/routing-guard@v3
wf_guard wf-src-minor 'on: [pull_request]' i2Dev-com/homefield/routing-guard@v0.1
wf_guard wf-src-later 'on: [pull_request]' i2Dev-com/homefield/routing-guard@v0.4.0
wf_guard wf-src-suffix 'on: [pull_request]' i2Dev-com/homefield/routing-guard@v0.3.0-rc1
wf_guard wf-src-main 'on: [pull_request]' i2Dev-com/homefield/routing-guard@main
wf_guard wf-src-short 'on: [pull_request]' i2Dev-com/homefield/routing-guard@${sha40%?}
wf_guard wf-src-sha 'on: [pull_request]' "i2Dev-com/homefield/routing-guard@${sha40}"
wf_guard wf-src-quoted 'on: [pull_request]' "'${action}'"
wf_guard wf-src-dquoted 'on: [pull_request]' "\"${action}\""
wf_guard wf-src-case 'on: [pull_request]' I2DEV-COM/HomeField/routing-guard@v0.3.0
wf_guard wf-on-push 'on: [push]' "$action"
wf_guard wf-on-prt 'on: pull_request_target' "$action"
wf_guard wf-on-list 'on: [push, pull_request]' "$action"
wf_guard wf-on-quoted '"on": pull_request' "$action"
wf_guard wf-on-squoted "'on': [push, pull_request]" "$action"
# A job whose routing the guard cannot read must stop adopt, with the guard's reason.
wf_guard wf-unreadable 'on: [pull_request]' "$action"
printf '  unsafe: {runs-on: self-hosted, steps: [{run: echo unsafe}]}\n' >>"$work/wf-unreadable/ci.yml"
# Guard text that is only text: inside a run: script.
mkdir -p "$work/wf-heredoc"
{
  header
  emit_job lint "$expr" "      - run: |" "          cat <<'X'" "$(guard ci.yml:lint | sed 's/^/    /')" "          X"
} >"$work/wf-heredoc/ci.yml"
# A guard step whose options adopt cannot read: a label set to nothing (the
# guard refuses it), and a with: written on one line.
mkdir -p "$work/wf-emptylabel" "$work/wf-flowwith" "$work/wf-withcomment"
{ header; emit_job lint "$expr" "$(guard_label '""' ci.yml:lint)"; } >"$work/wf-emptylabel/ci.yml"
{ header; emit_job lint "$expr" "      - uses: $action" '        with: {jobs: "ci.yml:lint"}'; } >"$work/wf-flowwith/ci.yml"
# ...but a comment after with: is still a block.
{ header; emit_job lint "$expr" "$(guard ci.yml:lint | sed 's/with:/with: # options/')"; } >"$work/wf-withcomment/ci.yml"
wf_guard wf-on-block "$(printf 'on:\n  push:\n    branches: [main]\n  pull_request:')" "$action"
wf_guard wf-on-items "$(printf 'on:\n  - push\n  - pull_request')" "$action"
wf_guard wf-on-filter "$(printf 'on:\n  pull_request:\n    paths-ignore:\n      - docs/**')" "$action"
wf_guard wf-on-flowfilter 'on: {pull_request: {branches: [main]}}' "$action"

# A guard step with an `if:` (or another key, $3) of its own, or in a job with one.
wf_stepif() {
  mkdir -p "$work/$1"
  { printf 'name: CI\non: [pull_request]\njobs:\n'; emit_job lint "$expr" "$(guard ci.yml:lint)" "        ${3:-if}: $2"; } >"$work/$1/ci.yml"
}
# wf_jobif <dir> <value> <before|after> [key]: the job's `if:` (or key) above runs-on or below the steps.
wf_jobif() {
  mkdir -p "$work/$1"
  {
    printf 'name: CI\non: [pull_request]\njobs:\n  lint:\n'
    [ "$3" != before ] || printf '    %s: %s\n' "${4:-if}" "$2"
    printf '    runs-on: %s\n    steps:\n      - uses: actions/checkout@v5\n%s\n' "$expr" "$(guard ci.yml:lint)"
    [ "$3" != after ] || printf '    %s: %s\n' "${4:-if}" "$2"
  } >"$work/$1/ci.yml"
}
wf_stepif wf-stepif-false 'false'
wf_stepif wf-stepif-expr "\${{ false }}"
wf_stepif wf-stepif-quoted "\"\${{ false }}\""
wf_stepif wf-stepif-cond "github.event_name == 'pull_request'"
wf_jobif wf-jobif-false 'false' before
wf_jobif wf-jobif-false-after "\${{ false }}" after
wf_jobif wf-jobif-cond "github.actor != 'dependabot[bot]'" before
# continue-on-error keeps a failing guard from failing the check
# (GHSA-f4px-f5g2-f9px).
wf_stepif wf-stepcoe-true 'true' continue-on-error
wf_stepif wf-stepcoe-expr "\${{ true }}" continue-on-error
wf_stepif wf-stepcoe-false 'false' continue-on-error
wf_stepif wf-stepcoe-cond "\${{ matrix.experimental }}" continue-on-error
wf_jobif wf-jobcoe-true 'true' before continue-on-error
wf_jobif wf-jobcoe-true-after "True" after continue-on-error
wf_jobif wf-jobcoe-false 'false' before continue-on-error
wf_jobif wf-jobcoe-cond "\${{ matrix.experimental }}" before continue-on-error
# The same keys quoted, which YAML reads as the same key.
wf_stepif wf-stepcoe-dq 'true' '"continue-on-error"'
wf_stepif wf-stepcoe-sq 'true' "'continue-on-error'"
wf_stepif wf-stepif-dq 'false' '"if"'
wf_jobif wf-jobcoe-dq 'true' before '"continue-on-error"'
wf_jobif wf-jobcoe-sq 'true' after "'continue-on-error'"

# The guard in a reusable workflow, called from a pull_request workflow.
# wf_reuse <dir> <caller on:> <extra keys of the calling job, \n-terminated>
wf_reuse() {
  mkdir -p "$work/$1"
  printf 'name: CI\n%s\njobs:\n  checks:\n%b    uses: ./.github/workflows/checks.yml\n' "$2" "$3" >"$work/$1/ci.yml"
  { printf 'name: Checks\non: workflow_call\njobs:\n'; emit_job lint "$expr" "$(guard checks.yml:lint)"; } >"$work/$1/checks.yml"
}
wf_reuse wf-reuse-ok 'on: pull_request' ''
wf_reuse wf-reuse-push 'on: push' ''
wf_reuse wf-reuse-false 'on: pull_request' "    if: \${{ false }}\n"
wf_reuse wf-reuse-cond 'on: pull_request' "    needs: x\n    if: github.event_name != 'push'\n"
wf_reuse wf-reuse-coe 'on: pull_request' "    continue-on-error: true\n"
wf_reuse wf-reuse-coe-cond 'on: pull_request' "    continue-on-error: \${{ vars.X == 'y' }}\n"
wf_reuse wf-reuse-filter "$(printf 'on:\n  pull_request:\n    branches: [main]')" ''
# Two jobs call the reusable workflow: a disabled one (if: false) and a usable
# one, in each order, and both disabled.
wf_reuse_two() {
  mkdir -p "$work/$1"
  printf 'name: CI\non: pull_request\njobs:\n  %s:\n%b    uses: ./.github/workflows/checks.yml\n  %s:\n%b    uses: ./.github/workflows/checks.yml\n' "$2" "$3" "$4" "$5" >"$work/$1/ci.yml"
  cp "$work/wf-reuse-ok/checks.yml" "$work/$1/checks.yml"
}
wf_reuse_two wf-reuse-mixed checks '' retired "    if: \${{ false }}\n"
wf_reuse_two wf-reuse-mixed-first retired "    if: \${{ false }}\n" checks ''
wf_reuse_two wf-reuse-two-false checks "    if: \${{ false }}\n" retired "    if: false\n"
wf_reuse_two wf-reuse-coe-mixed checks "    continue-on-error: true\n" retired ''
mkdir -p "$work/wf-reuse-uncalled" "$work/wf-reuse-chain"
cp "$work/wf-reuse-ok/checks.yml" "$work/wf-reuse-uncalled/checks.yml"
{ header; emit_job lint ubuntu-latest; } >"$work/wf-reuse-uncalled/ci.yml"
# Two levels: ci.yml calls outer.yml, which calls checks.yml. Not followed.
cp "$work/wf-reuse-ok/checks.yml" "$work/wf-reuse-chain/checks.yml"
printf 'name: CI\non: pull_request\njobs:\n  outer:\n    uses: ./.github/workflows/outer.yml\n' >"$work/wf-reuse-chain/ci.yml"
printf 'name: Outer\non: workflow_call\njobs:\n  checks:\n    uses: ./.github/workflows/checks.yml\n' >"$work/wf-reuse-chain/outer.yml"

# Shaped like i2Dev-com/i2dev: the guard is in a reusable workflow, called by
# a job that waits for a change filter, from a pull_request trigger with
# branch and path filters.
mkdir -p "$work/wf-i2dev" "$work/wf-snap"
cat >"$work/wf-i2dev/ci.yml" <<'EOF'
name: CI
on:
  push:
    branches: [main]
  pull_request:
    branches: [main]
    paths-ignore:
      - 'docs/**'
      - '*.md'
jobs:
  changes:
    runs-on: ubuntu-latest
    outputs:
      code: ${{ steps.filter.outputs.code }}
    steps:
      - uses: actions/checkout@v5
  checks:
    needs: changes
    if: ${{ needs.changes.outputs.code == 'true' && github.event_name != 'push' }}
    uses: ./.github/workflows/ci-checks.yml
EOF
{
  printf 'name: Checks\non: workflow_call\njobs:\n'
  emit_job lint "$expr" "$(guard ci-checks.yml:lint ci-checks.yml:test)"
  emit_job test "$expr"
} >"$work/wf-i2dev/ci-checks.yml"
# Shaped like i2Dev-com/snap: a bare pull_request trigger and no conditions.
{
  printf 'name: CI\non:\n  push:\n    branches: [main]\n  pull_request:\njobs:\n'
  emit_job lint "$expr" "$(guard ci.yml:lint ci.yml:test)"
  emit_job test "$expr"
} >"$work/wf-snap/ci.yml"

# run_fn [VAR=value ...] -- <function> [args]: sets out and rc. No terminal.
# TMPDIR is a directory of ours, to see that adopt cleans up after itself.
run_fn() {
  local envs=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do
    envs+=("$1")
    shift
  done
  shift
  : >"$calls"
  # shellcheck disable=SC2016  # the -c script is expanded by the inner bash
  out="$(env -i HOME="$work" PATH="$stubs" TMPDIR="$work/tmp" CALLS="$calls" HOMEFIELD_SOURCE_ONLY=1 "${envs[@]+"${envs[@]}"}" \
    "$BASH" -c '. "$1"; shift; "$@"' _ "$ROOT/bin/homefield" "$@" 2>&1 </dev/null)"
  rc=$?
}
called() { grep -c -e "$1" "$calls" || true; }
# called_any <pattern>...: calls that match any of them.
called_any() {
  local args=() p
  for p in "$@"; do args+=(-e "$p"); done
  grep -c "${args[@]}" "$calls" || true
}
# adopt <env...> -- <adopt args>: an adopt run on acme/app with the usual stubs.
adopt() {
  local envs=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do
    envs+=("$1")
    shift
  done
  shift
  run_fn GH_GROUPS="$work/groups-selected" GH_MEMBERS="$work/members-other" GH_WF="$work/wf-ready" \
    "${envs[@]+"${envs[@]}"}" -- cmd_adopt --repo acme/app "$@"
}
put_path="orgs/acme/actions/runner-groups/42/repositories/555"

# ── Arguments ──────────────────────────────────────────────────────────────
echo "arguments"
run_fn -- cmd_adopt
record "no --repo: refused" "nonzero/yes" "$(nonzero "$rc")/$(has "$out" '--repo <owner>/<repo> is required')"
run_fn -- cmd_adopt --repo a/b --repo c/d
record "two repositories: refused" "nonzero/yes" "$(nonzero "$rc")/$(has "$out" 'one --repo at a time')"
run_fn -- cmd_adopt --repo not-a-repo
record "a bad repository name: refused" "nonzero/yes/0" "$(nonzero "$rc")/$(has "$out" 'must be <owner>/<repo>')/$(called gh)"
run_fn -- cmd_adopt --repo 'a/b;c'
record "shell characters in the name: refused" "nonzero" "$(nonzero "$rc")"
run_fn -- cmd_adopt --repo acme/app --jobs 'ci.yml'
record "--jobs without a job id: refused" "nonzero/yes" "$(nonzero "$rc")/$(has "$out" 'ci.yml:lint')"
run_fn -- cmd_adopt --repo acme/app --label 'a b'
record "a bad label: refused" "nonzero/yes/0" "$(nonzero "$rc")/$(has "$out" '--label must be one label')/$(called gh)"
run_fn -- cmd_adopt --repo acme/app --label linux
record "a reserved label: refused with the guard's reason" "nonzero/yes/0" "$(nonzero "$rc")/$(has "$out" 'custom label')/$(called gh)"
# The reason is in adopt's own message, without the guard's colours: the guard
# prints a refusal on stderr, so adopt has to capture that too.
record "...the reason is in the refusal line, not coloured" "1/no" \
  "$(printf '%s\n' "$out" | grep -c 'cannot be routed on: .*custom label')/$(has "$out" $'\033')"
run_fn -- cmd_adopt --repo acme/app --frobnicate
record "an unknown option: refused" "nonzero/yes" "$(nonzero "$rc")/$(has "$out" 'unknown option --frobnicate')"
mv "$stubs/gh" "$work/gh.away"
run_fn -- cmd_adopt --repo acme/app
record "without gh: stops, saying so" "nonzero/yes" "$(nonzero "$rc")/$(has "$out" 'adopt needs gh')"
mv "$work/gh.away" "$stubs/gh"
mv "$stubs/python3" "$work/python3.away"
run_fn -- cmd_adopt --repo acme/app
record "without python3: stops, saying so" "nonzero/yes/0" "$(nonzero "$rc")/$(has "$out" 'adopt needs python3')/$(called gh)"
mv "$work/python3.away" "$stubs/python3"

# ── Repository ─────────────────────────────────────────────────────────────
echo "repository"
adopt GH_REPO="$(printf 'false\t555\tmain\tOrganization')" --
record "a public repository: refused, before anything else" "nonzero/yes/yes/0/0" \
  "$(nonzero "$rc")/$(has "$out" 'acme/app is public')/$(has "$out" 'Security model')/$(called 'runner-groups')/$(called 'variable set')"
adopt GH_REPO_FAIL=1 --
record "a repository that is not found: refused" "nonzero/yes/0" "$(nonzero "$rc")/$(has "$out" 'could not read acme/app')/$(called 'runner-groups')"
adopt GH_REPO="garbage" --
record "an answer that cannot be read: refused" "nonzero/yes" "$(nonzero "$rc")/$(has "$out" 'cannot read')"
adopt GH_CI_RUNNER=hosted -- --no-switch
record "a private repository is reported with its default branch" "0/yes" "$rc/$(has "$out" 'acme/app is private (default branch main)')"
record "the repository is read once" "1" "$(called '^gh api repos/acme/app ')"

# ── Runner group ───────────────────────────────────────────────────────────
echo "runner group"
adopt --
record "selected group, not a member: added" "0/yes" "$rc/$(has "$out" 'added acme/app to homefield-ci')"
record "...by a PUT to the group's repository path, once" "1" "$(called "gh api -X PUT $put_path")"
record "...after reading the members, paginated" "1" "$(called '--paginate orgs/acme/actions/runner-groups/42/repositories?per_page=100')"

adopt GH_MEMBERS="$work/members-with" --
record "already a member: no PUT" "0/yes/0" "$rc/$(has "$out" 'already has access to homefield-ci')/$(called 'X PUT')"
adopt GH_MEMBERS="$work/members-empty" --
record "no members at all: added" "1" "$(called 'X PUT')"
adopt GH_GROUPS="$work/groups-case" --
record "the group name is found in any case" "1/yes" "$(called 'X PUT')/$(has "$out" 'added acme/app to HomeField-CI')"
adopt GH_GROUPS="$work/groups-all" --
record "a group open to all repositories: a warning, no PUT, no members read" "0/yes/yes/0/0" \
  "$rc/$(has "$out" 'warning: runner group homefield-ci is open to all')/$(has "$out" 'already has access and nothing was added')/$(called 'X PUT')/$(called 'repositories?')"
adopt GH_GROUPS="$work/groups-selected-public" --
record "selected but allowing public repositories: a warning, and still added" "0/yes/1" "$rc/$(has "$out" 'warning: runner group homefield-ci allows public repositories')/$(called 'X PUT')"
record "...the summary does not read as a clean add" "yes" "$(has "$out" 'runner group added, but the group allows public repositories;')"
record "...pointing at the setting to turn off" "yes" "$(has "$out" 'turn off Allow public repositories')"
adopt GH_GROUPS="$work/groups-selected-public" GH_MEMBERS="$work/members-with" --
record "...a member already: said so, with the same note" "yes/yes" "$(has "$out" 'already a member, but the group allows public repositories')/$(has "$out" 'allows public repositories. ')"
adopt GH_GROUPS="$work/groups-selected-public" -- --dry-run
record "...a dry run: would be added, with the note, nothing written" "yes/0" "$(has "$out" 'would be added (dry run), but the group allows public repositories')/$(called 'X PUT')"
adopt GH_GROUPS="$work/groups-selected-public" GH_WF="$work/wf-noguard" --
record "...routing not ready: not added, and the warning is given once" "nonzero/yes/0/1" "$(nonzero "$rc")/$(has "$out" 'runner group: not added, because the routing is not ready')/$(called 'X PUT')/$(printf '%s\n' "$out" | grep -c 'allows public repositories. ')"
adopt GH_GROUPS="$work/groups-all-public" --
record "open to all and allowing public ones: the existing warning says both" "0/yes/yes" "$rc/$(has "$out" 'is open to all repositories in acme and allows public ones')/$(has "$out" 'already open (all), but the group allows public repositories')"
adopt GH_GROUPS="$work/groups-selected" --
record "a selected group with public repositories off: no such warning" "no" "$(has "$out" 'allows public')"
adopt GH_GROUPS="$work/groups-private" --
record "a group open to private repositories: the same" "0/yes/0" "$rc/$(has "$out" 'open to private repositories')/$(called 'X PUT')"
adopt GH_GROUPS="$work/groups-none" --
record "no such group: a note that nothing was done, and it goes on" "0/yes/0/yes" \
  "$rc/$(has "$out" 'has no group homefield-ci')/$(called 'X PUT')/$(has "$out" 'routing: ready')"
adopt -- --group Default
record "the Default group: skipped, no group call" "0/yes/0" "$rc/$(has "$out" 'runner group: skipped, the Default group')/$(called 'runner-groups')"
adopt -- --group default
record "...in any case" "0/0" "$rc/$(called 'runner-groups')"
adopt GH_REPO="$(printf 'true\t555\tmain\tUser')" --
record "a personal account: skipped, no group call" "0/yes/0" "$rc/$(has "$out" 'personal account')/$(called 'runner-groups')"
adopt GH_LIST_FAIL=1 --
record "groups cannot be listed: a warning, no PUT, and it goes on" "0/yes/yes/0/yes" \
  "$rc/$(has "$out" 'warning: could not check runner group access; add acme/app by hand')/$(has "$out" 'docs/adopting.md step 5')/$(called 'X PUT')/$(has "$out" 'routing: ready')"
adopt GH_MEMBERS_FAIL=1 --
record "members cannot be read: a warning, no PUT" "0/yes/0" "$rc/$(has "$out" 'could not read the repositories of runner group')/$(called 'X PUT')"
adopt GH_PUT_FAIL=1 --
record "the PUT fails: an error naming the manual step" "nonzero/yes" "$(nonzero "$rc")/$(has "$out" 'could not add acme/app to runner group homefield-ci; add it by hand')"
adopt -- --group other-group
record "--group picks the group" "0/yes" "$rc/$(has "$out" 'has no group other-group')"

# ── Routing ────────────────────────────────────────────────────────────────
echo "routing"
adopt --
record "ready workflows: the guard passes and the jobs are listed" "0/yes/yes" \
  "$rc/$(has "$out" 'routing: ready')/$(has "$out" 'ci.yml:lint ci.yml:test')"
record "...so CI_RUNNER is set to local through route" "1" "$(called 'variable set CI_RUNNER --repo acme/app --body local')"
record "...nothing else is written" "0" "$(called 'X POST')"
record "the workflow directory is listed at the default branch, then every file is fetched" "1/1/1" \
  "$(called '^gh api -X GET repos/acme/app/contents/.github/workflows -f ref=main')/$(called 'workflows/ci.yml ')/$(called 'workflows/my%20flow.yaml ')"
record "...a name with a space is encoded, and README.md is not fetched" "0" "$(called 'README.md')"
record "...the raw media type is asked for" "2" "$(called "Accept: application/vnd.github.raw")"
record "the downloaded workflows are removed afterwards" "0" "$(find "$work/tmp" -mindepth 1 | wc -l | tr -d ' ')"
record "the last lines say what is left by hand" "yes/yes" "$(has "$out" 'CI_RUNNER set to local')/$(has "$out" 'docs/adopting.md, steps 6 and 7')"

adopt GH_WF="$work/wf-noguard" --
record "no guard step: not ready, nothing switched, exit 1" "nonzero/yes/yes/0" \
  "$(nonzero "$rc")/$(has "$out" 'routing: not ready')/$(has "$out" 'no routing-guard step in .github/workflows')/$(called 'variable set')"
record "...the canonical expression is printed" "yes" "$(has "$out" "runs-on: $expr")"
record "...and the guard step, with the jobs that are routed" "yes/yes/yes" \
  "$(has "$out" 'uses: i2Dev-com/homefield/routing-guard@v0.3.0')/$(has "$out" '            ci.yml:lint')/$(has "$out" '            ci.yml:test')"
record "...the default label is not written into the guard" "no" "$(has "$out" 'label: homefield-ci')"
record "...and the last line says to merge first" "yes" "$(has "$out" 'not switched: merge the routing first, then run homefield adopt again')"

adopt GH_WF="$work/wf-mismatch" --
record "a guard that differs from the routed jobs: not ready" "nonzero/yes/yes/0" \
  "$(nonzero "$rc")/$(has "$out" 'would fail')/$(has "$out" 'ci.yml:test opts in but is not in the expected list')/$(called 'variable set')"
adopt GH_WF="$work/wf-norouted" --
record "a guard with no routed job: not ready" "nonzero/yes/0" "$(nonzero "$rc")/$(has "$out" 'no job uses the routing expression')/$(called 'variable set')"
record "...the snippet has a placeholder job" "yes" "$(has "$out" 'ci.yml:<job-id>')"
adopt GH_WF="$work/wf-nonexistent" --
record "no .github/workflows at all: not ready, not an error to look" "nonzero/yes/yes/0" \
  "$(nonzero "$rc")/$(has "$out" 'no routing-guard step')/$(has "$out" 'cache keys: no workflow files')/$(called 'variable set')"
adopt GH_WF="$work/wf-ready" GH_WF_FAIL=1 --
record "the directory cannot be listed (not a 404): an error" "nonzero/yes/0" "$(nonzero "$rc")/$(has "$out" 'could not list .github/workflows in acme/app')/$(called 'variable set')"
adopt PY_LIST_FAIL=1 GH_WF="$work/wf-noguard" --
record "the routed-jobs listing crashes: adopt stops with that, not with an empty list" "nonzero/yes/0" \
  "$(nonzero "$rc")/$(has "$out" 'routing_guard.py could not list the routed jobs')/$(called 'variable set')"
adopt GH_WF="$work/wf-noguard" -- --jobs 'a.yml:x,b.yml:y'
record "--jobs fills the snippet's expected list" "yes/yes/no" "$(has "$out" '            a.yml:x')/$(has "$out" '            b.yml:y')/$(has "$out" '            ci.yml:lint')"

adopt GH_WF="$work/wf-label" --
record "a guard with another label: that label is used" "0/yes/yes/1" \
  "$rc/$(has "$out" 'routing: ready')/$(has "$out" 'these jobs are routed: ci.yml:lint')/$(called 'variable set CI_RUNNER --repo acme/app --body local')"
adopt GH_WF="$work/wf-label" -- --label homefield-ci
record "...unless --label says otherwise: not ready, and only that label's jobs count" \
  "nonzero/yes/yes/0" \
  "$(nonzero "$rc")/$(has "$out" 'uses label acme-ci, but --label is homefield-ci')/$(has "$out" 'no job uses the routing expression for label homefield-ci')/$(called 'variable set')"
adopt GH_WF="$work/wf-label" -- --label acme-ci
record "...--label that agrees is fine" "0/1" "$rc/$(called 'variable set CI_RUNNER --repo acme/app --body local')"
adopt GH_WF="$work/wf-noguard" -- --label acme-ci
record "snippets carry the chosen label in the expression and the guard" "yes/yes" "$(has "$out" "runs-on: $expr_acme")/$(has "$out" '          label: acme-ci')"

# Routing options: events, dependabot and fallback, held to the guard the way
# the label is.
adopt GH_WF="$work/wf-push" --
record "a guard with events push: that is used, and the jobs are routed" "0/yes/yes/1" \
  "$rc/$(has "$out" 'routing: ready')/$(has "$out" 'these jobs are routed: ci.yml:lint')/$(called 'variable set CI_RUNNER --repo acme/app --body local')"
adopt GH_WF="$work/wf-push" -- --events push
record "...--events that agrees is fine" "0/1" "$rc/$(called 'variable set CI_RUNNER --repo acme/app --body local')"
adopt GH_WF="$work/wf-push" -- --events pull_request
record "...--events that differs: refused with the reason, nothing switched" "nonzero/yes/yes/0" \
  "$(nonzero "$rc")/$(has "$out" 'uses events push, but --events is pull_request')/$(has "$out" 'no job uses the routing expression')/$(called 'variable set')"
adopt GH_WF="$work/wf-combo" -- --events 'schedule push' --dependabot local --fallback ubuntu-24.04-arm
record "all three options, in another order and separator: agree with a block-scalar guard" "0/yes/1" \
  "$rc/$(has "$out" 'routing: ready')/$(called 'variable set CI_RUNNER --repo acme/app --body local')"
adopt GH_WF="$work/wf-combo" --
record "...without flags the guard's options are used" "0/1" "$rc/$(called 'variable set CI_RUNNER --repo acme/app --body local')"
record "...and a standard fallback is not warned about" "yes/no" \
  "$(has "$out" 'fallback image: ubuntu-24.04-arm is a standard')/$(has "$out" 'warning: fallback')"
adopt GH_WF="$work/wf-typo" --
record "a fallback GitHub does not list (ubuntu-lates): warned, not refused" "0/yes/1" \
  "$rc/$(has "$out" 'warning: fallback ubuntu-lates is not one of')/$(called 'variable set CI_RUNNER --repo acme/app --body local')"
adopt GH_WF="$work/wf-combo" -- --events 'push,schedule,workflow_dispatch'
record "...a larger events set differs" "nonzero/yes" "$(nonzero "$rc")/$(has "$out" 'but --events is push,schedule,workflow_dispatch')"
adopt GH_WF="$work/wf-combo" -- --dependabot hosted
record "...--dependabot that differs: refused with the reason" "nonzero/yes/0" \
  "$(nonzero "$rc")/$(has "$out" 'uses dependabot local, but --dependabot is hosted')/$(called 'variable set')"
adopt GH_WF="$work/wf-combo" -- --fallback ubuntu-latest
record "...--fallback that differs: refused with the reason" "nonzero/yes/0" \
  "$(nonzero "$rc")/$(has "$out" 'uses fallback ubuntu-24.04-arm, but --fallback is ubuntu-latest')/$(called 'variable set')"
adopt -- --events push
record "a guard on the defaults, --events push: refused" "nonzero/yes/0" \
  "$(nonzero "$rc")/$(has "$out" 'uses events pull_request, but --events is push')/$(called 'variable set')"
adopt -- --dependabot local
record "...and --dependabot local" "nonzero/yes" "$(nonzero "$rc")/$(has "$out" 'uses dependabot hosted, but --dependabot is local')"
adopt -- --fallback macos-latest
record "...and --fallback macos-latest" "nonzero/yes" "$(nonzero "$rc")/$(has "$out" 'uses fallback ubuntu-latest, but --fallback is macos-latest')"
adopt GH_WF="$work/wf-prt" --
record "a guard with events pull_request_target: not ready, with the guard's reason" "nonzero/yes/0" \
  "$(nonzero "$rc")/$(has "$out" 'pull_request_target is refused')/$(called 'variable set')"
adopt GH_WF="$work/wf-noguard" -- --events 'push,schedule' --dependabot local --fallback ubuntu-24.04-arm
record "no guard yet: the expression and the snippet carry the options" "nonzero/yes/yes/yes/yes/no" \
  "$(nonzero "$rc")/$(has "$out" "runs-on: $expr_combo")/$(has "$out" '          events: push, schedule')/$(has "$out" '          dependabot: local')/$(has "$out" '          fallback: ubuntu-24.04-arm')/$(has "$out" 'label:')"
adopt GH_WF="$work/wf-noguard" --
record "...the defaults are not written into the guard" "no/no/no" \
  "$(has "$out" 'events:')/$(has "$out" 'dependabot:')/$(has "$out" 'fallback:')"
run_fn -- cmd_adopt --repo acme/app --events pull_request_target
record "--events pull_request_target: refused, named, before anything is read" "nonzero/yes/0" \
  "$(nonzero "$rc")/$(has "$out" 'pull_request_target is refused')/$(called gh)"
run_fn -- cmd_adopt --repo acme/app --events bogus
record "--events with another name: refused" "nonzero/yes/0" "$(nonzero "$rc")/$(has "$out" "'bogus' is not one of")/$(called gh)"
run_fn -- cmd_adopt --repo acme/app --events ''
record "--events with nothing: refused" "nonzero/yes/0" "$(nonzero "$rc")/$(has "$out" '--events needs a value')/$(called gh)"
run_fn -- cmd_adopt --repo acme/app --dependabot maybe
record "--dependabot other than hosted or local: refused" "nonzero/yes/0" "$(nonzero "$rc")/$(has "$out" 'must be hosted or local')/$(called gh)"
run_fn -- cmd_adopt --repo acme/app --fallback self-hosted
record "--fallback that is not a hosted image: refused" "nonzero/yes/0" "$(nonzero "$rc")/$(has "$out" 'bare GitHub-hosted image name')/$(called gh)"

# Two guards: a stale one on the default label, whose check fails, and a
# passing one on acme-ci. The routed jobs count under either guard, and the
# passing guard's label is the one the snippet and messages use.
adopt GH_WF="$work/wf-twoguards" --
record "two guards, one stale: not ready, with the failing check" "nonzero/yes/no" \
  "$(nonzero "$rc")/$(has "$out" 'would fail')/$(has "$out" 'no job uses the routing expression')"
record "...the routed jobs are listed from the passing guard" "yes/yes" \
  "$(has "$out" '            ci.yml:lint')/$(has "$out" '            ci.yml:test')"
record "...the passing guard's label is the one advised" "yes/no" \
  "$(has "$out" "runs-on: $expr_acme")/$(has "$out" "runs-on: $expr")"

# ── Group access waits for the routing ─────────────────────────────────────
echo "group access order"
adopt GH_WF="$work/wf-noguard" --
record "routing not ready, not a member: no PUT, said so, exit 1" "nonzero/0/yes" \
  "$(nonzero "$rc")/$(called 'X PUT')/$(has "$out" 'runner group: not added, because the routing is not ready')"
record "...the group's members were still read, to tell" "1" "$(called 'repositories?per_page=100')"
record "...routing is reported before the runner group" "yes" \
  "$(before "$out" 'routing: not ready' 'runner group: not added')"
adopt GH_WF="$work/wf-noguard" -- --dry-run
record "...the same in a dry run" "nonzero/0/yes" "$(nonzero "$rc")/$(called 'X PUT')/$(has "$out" 'runner group: not added')"
adopt GH_WF="$work/wf-noguard" GH_MEMBERS="$work/members-with" --
record "routing not ready but already a member: a warning that it can reach the runner" "nonzero/0/yes/yes" \
  "$(nonzero "$rc")/$(called 'X PUT')/$(has "$out" 'warning: acme/app is already in runner group homefield-ci')/$(has "$out" 'although its routing is not ready')"
adopt GH_WF="$work/wf-noguard" GH_LIST_FAIL=1 --
record "routing not ready and groups not readable: a warning that does not send you to add it" "nonzero/0/yes/no" \
  "$(nonzero "$rc")/$(called 'X PUT')/$(has "$out" 'could not check runner group access')/$(has "$out" 'by hand')"
adopt GH_WF="$work/wf-noguard" GH_GROUPS="$work/groups-all" --
record "routing not ready, group open to all: the existing warning, no PUT" "nonzero/0/yes" \
  "$(nonzero "$rc")/$(called 'X PUT')/$(has "$out" 'is open to all')"
adopt --
record "routing ready: the PUT comes after the routing is reported" "1/yes" \
  "$(called "gh api -X PUT $put_path")/$(before "$out" 'routing: ready' 'runner group: added')"
record "...and the cache keys, then the switch, follow the group" "yes/yes" \
  "$(before "$out" 'cache keys:' 'runner group: added')/$(before "$out" 'runner group: added' 'CI_RUNNER')"
adopt GH_WF="$work/wf-src-v1" --
record "a guard that is not the pinned action: nothing added to the group" "nonzero/0" "$(nonzero "$rc")/$(called 'X PUT')"

# ── What counts as a guard ─────────────────────────────────────────────────
echo "guard source and triggers"
# route_case <description> <fixture> <ready|not> <text in the output, or !text>
route_case() {
  local desc="$1" dir="$2" want="$3" needle="$4" wanth=yes wantrc
  if [ "${needle#!}" != "$needle" ]; then
    wanth=no
    needle="${needle#!}"
  fi
  adopt GH_WF="$work/$dir" --
  if [ "$want" = ready ]; then wantrc="0/1/1"; else wantrc="nonzero/0/0"; fi
  record "$desc" "$wantrc/$wanth" "$(nonzero "$rc")/$(called 'variable set')/$(called 'X PUT')/$(has "$out" "$needle")"
}
may_not_run='the routing guard may not run on every pull request'
recognizes="adopt recognizes ${action}, the release this copy of homefield checks with, or a full commit SHA"
route_case "another repository's routing-guard: not a guard, and says what it uses" wf-src-other not "ci.yml:9 uses other-org/homefield/routing-guard@v0.3.0, but $recognizes"
route_case "@v1, a major only: not a guard" wf-src-v1 not "uses i2Dev-com/homefield/routing-guard@v1, but $recognizes"
route_case "@v3, a major only: not a guard" wf-src-v3 not "uses i2Dev-com/homefield/routing-guard@v3, but $recognizes"
route_case "@v0.1, a minor only: not a guard" wf-src-minor not "uses i2Dev-com/homefield/routing-guard@v0.1, but $recognizes"
route_case "@v0.3.0-rc1, a suffix: not a guard" wf-src-suffix not "uses i2Dev-com/homefield/routing-guard@v0.3.0-rc1, but $recognizes"
route_case "the current release, @v0.3.0: ready" wf-on-list ready "routing: ready, the guard passes and these jobs are routed: ci.yml:lint"
route_case "another exact release, @v0.4.0: not a guard, its rules may differ" wf-src-later not "uses i2Dev-com/homefield/routing-guard@v0.4.0, but $recognizes"
route_case "...and says to pin this release or install that one" wf-src-later not "v0.4.0 may have other rules: pin v0.3.0, or install homefield v0.4.0"
route_case "@main: not a guard" wf-src-main not "uses i2Dev-com/homefield/routing-guard@main, but $recognizes"
route_case "...and nothing else is said to be usable" wf-src-main not "no routing-guard step that runs on pull requests"
route_case "a 39-character ref is not a commit: not a guard" wf-src-short not "but $recognizes"
route_case "a full commit SHA: ready, with a warning naming the line" wf-src-sha ready "ci.yml:9: pinned to a commit (adopt checks it as it would a release tag)"
route_case "a single-quoted uses: a guard" wf-src-quoted ready "!$recognizes"
route_case "a double-quoted uses: a guard" wf-src-dquoted ready "!$recognizes"
route_case "the owner and repository are compared without case" wf-src-case ready "!$recognizes"
route_case "...with no warning about the guard" wf-src-case ready "!$may_not_run"

route_case "a push-only workflow: the guard does not run on pull requests" wf-on-push not "ci.yml:9 does not run on pull requests: ci.yml does not run on pull_request"
route_case "...so there is no guard" wf-on-push not "no routing-guard step that runs on pull requests"
route_case "pull_request_target: not a guard, and the reason says why" wf-on-prt not "runs on pull_request_target, which runs the base branch's workflow files"
route_case "a job written as a {...} mapping: not ready, with the guard's reason" wf-unreadable not "ci.yml:$(grep -n 'unsafe:' "$work/wf-unreadable/ci.yml" | cut -d: -f1): unreadable job id"
route_case "guard text inside a run: script is not a step: no guard" wf-heredoc not "no routing-guard step in .github/workflows"
route_case "label: set to nothing: not ready, and the reason says so" wf-emptylabel not "sets label: to nothing, which the guard refuses"
route_case "a with: on one line: not ready, and the reason says so" wf-flowwith not "has its with: on one line (line 9), which adopt does not read"
route_case "a comment after with: does not make it a one-line with:" wf-withcomment ready "!on one line"
route_case "arch: x64 on the step: refused, naming the VM" wf-arch-x64 not "uses arch x64, but adopt sets up an arm64 VM"
route_case "...the step's own check passes, x64 being what CI runs" wf-arch-x64 not "!would fail"
route_case "arch: arm64 on the step: ready like the default" wf-arch-arm64 ready "routing: ready"
route_case "arch: amd64 on the step: refused, with the guard's own reason too" wf-arch-amd64 not "must be arm64 or x64"
route_case "on: [push, pull_request]" wf-on-list ready "!$may_not_run"
route_case "\"on\": quoted" wf-on-quoted ready "!$may_not_run"
route_case "'on': quoted, as a list" wf-on-squoted ready "!$may_not_run"
route_case "on: as a block, with the options of push" wf-on-block ready "!$may_not_run"
route_case "on: as a list of items" wf-on-items ready "!$may_not_run"
route_case "pull_request with paths-ignore: ready, with a warning" wf-on-filter ready "ci.yml:3: the pull_request trigger has paths-ignore filters"
route_case "...that says what to check" wf-on-filter ready "Check that every pull request that changes .github/workflows still runs it"
route_case "pull_request in a flow mapping with branches: ready, with a warning" wf-on-flowfilter ready "the pull_request trigger has branches filters"

route_case "if: false on the step: not a guard" wf-stepif-false not "never runs: its step has an if: that is false"
route_case "if: \${{ false }} on the step: not a guard" wf-stepif-expr not "has an if: that is false"
route_case "if: \"\${{ false }}\" on the step: not a guard" wf-stepif-quoted not "has an if: that is false"
route_case "another if: on the step: ready, with a warning" wf-stepif-cond ready "ci.yml:13: its step has an if: condition"
route_case "if: false on the job, above runs-on: not a guard" wf-jobif-false not "never runs: its job lint has an if: that is false"
route_case "if: \${{ false }} on the job, after the steps: not a guard" wf-jobif-false-after not "never runs: its job lint has an if: that is false"
route_case "another if: on the job: ready, with a warning" wf-jobif-cond ready "ci.yml:5: its job lint has an if: condition"

route_case "continue-on-error: true on the step: not a guard" wf-stepcoe-true not "cannot fail the check: its step has continue-on-error: true (line 13)"
route_case "\"continue-on-error\": true on the step: not a guard" wf-stepcoe-dq not "its step has continue-on-error: true"
route_case "'continue-on-error': true on the step: not a guard" wf-stepcoe-sq not "its step has continue-on-error: true"
route_case "\"if\": false on the step: not a guard" wf-stepif-dq not "its step has an if: that is false"
route_case "\"continue-on-error\": true on the job: not a guard" wf-jobcoe-dq not "its job lint has continue-on-error: true"
route_case "'continue-on-error': true on the job, after the steps: not a guard" wf-jobcoe-sq not "its job lint has continue-on-error: true"
route_case "continue-on-error: \${{ true }} on the step: not a guard" wf-stepcoe-expr not "its step has continue-on-error: true"
route_case "continue-on-error: false on the step: ready" wf-stepcoe-false ready "!continue-on-error"
route_case "continue-on-error: an expression on the step: ready, with a warning" wf-stepcoe-cond ready "ci.yml:13: its step has a continue-on-error: condition"
route_case "continue-on-error: true on the job, above runs-on: not a guard" wf-jobcoe-true not "cannot fail the check: its job lint has continue-on-error: true"
route_case "continue-on-error: True on the job, after the steps: not a guard" wf-jobcoe-true-after not "cannot fail the check: its job lint has continue-on-error: true"
route_case "continue-on-error: false on the job: ready" wf-jobcoe-false ready "!continue-on-error"
route_case "continue-on-error: an expression on the job: ready, with a warning" wf-jobcoe-cond ready "ci.yml:5: its job lint has a continue-on-error: condition"

route_case "a reusable workflow called from a pull_request workflow: ready" wf-reuse-ok ready "!$may_not_run"
route_case "a reusable workflow that nothing calls: not a guard" wf-reuse-uncalled not "only reusable (workflow_call) and no workflow that runs on pull_request calls it with uses: ./.github/workflows/checks.yml"
route_case "...called only from a push workflow: not a guard" wf-reuse-push not "only reusable (workflow_call)"
route_case "...called through another reusable workflow: not followed, not a guard" wf-reuse-chain not "adopt follows one level of calls"
route_case "...called by a job with if: false: not a guard" wf-reuse-false not "job checks at ci.yml:4, which calls checks.yml, has an if: that is false"
route_case "...called by a job with another if: ready, with a warning" wf-reuse-cond ready "ci.yml:6: job checks, which calls checks.yml, has an if: condition"
route_case "...called by one job with if: false and another without: ready" wf-reuse-mixed ready "!never runs"
route_case "...the same, the disabled job first: ready" wf-reuse-mixed-first ready "!never runs"
route_case "...called only by jobs with if: false: not a guard, naming each" wf-reuse-two-false not "job checks at ci.yml:4, which calls checks.yml, has an if: that is false"
route_case "...naming the second too" wf-reuse-two-false not "job retired at ci.yml:7, which calls checks.yml, has an if: that is false"
route_case "...called by a job with continue-on-error: true: not a guard" wf-reuse-coe not "job checks at ci.yml:4, which calls checks.yml, has continue-on-error: true"
route_case "...called by a job with a continue-on-error expression: ready, with a warning" wf-reuse-coe-cond ready "ci.yml:5: job checks, which calls checks.yml, has a continue-on-error: condition"
route_case "...called by one job with continue-on-error: true and another without: ready" wf-reuse-coe-mixed ready "!cannot fail the check"
route_case "...called from a pull_request with branches: ready, with a warning" wf-reuse-filter ready "ci.yml:3: the pull_request trigger has branches filters"

echo "adopter shapes"
adopt GH_WF="$work/wf-i2dev" --
record "guard in a reusable workflow, called by a conditional job: ready" "0/1/1" "$rc/$(called 'variable set')/$(called 'X PUT')"
record "...with a warning for the trigger's filters" "yes/yes" \
  "$(has "$out" 'ci.yml:5: the pull_request trigger has branches, paths-ignore filters')/$(has "$out" 'Check that every pull request that changes .github/workflows still runs it')"
record "...and one for the calling job's condition" "yes" "$(has "$out" 'ci.yml:19: job checks, which calls ci-checks.yml, has an if: condition')"
adopt GH_WF="$work/wf-snap" --
record "guard beside a bare pull_request trigger: ready, and no warning about it" "0/1/no" "$rc/$(called 'variable set')/$(has "$out" "$may_not_run")"
adopt GH_WF="$work/wf-snap" -- --dry-run
record "...in a dry run too" "0/no" "$rc/$(has "$out" "$may_not_run")"
adopt GH_WF="$work/wf-src-main" GH_CI_RUNNER=hosted -- --dry-run
record "a guard that is not the pinned action in a dry run: not ready, nothing written" "nonzero/0/0" "$(nonzero "$rc")/$(called 'X PUT')/$(called 'variable set')"

# ── The switch ─────────────────────────────────────────────────────────────
echo "switch"
adopt GH_CI_RUNNER=local --
record "already local: said so, nothing written" "0/yes/0" "$rc/$(has "$out" 'CI_RUNNER is already local; nothing to change')/$(called 'variable set')"
adopt GH_CI_RUNNER=hosted --
record "hosted: switched, and the previous value is shown" "1/yes" "$(called 'variable set')/$(has "$out" 'CI_RUNNER hosted -> local')"
adopt -- --no-switch
record "--no-switch: ready, but nothing written" "0/yes/0" "$rc/$(has "$out" 'not switching (--no-switch)')/$(called 'variable set')"
record "...the PUT for group access still happens" "1" "$(called 'X PUT')"
adopt GH_WF="$work/wf-noguard" -- --no-switch
record "--no-switch does not hide a routing that is not ready" "nonzero" "$(nonzero "$rc")"
adopt GH_WF="$work/wf-noguard" GH_CI_RUNNER=local --
record "not ready but already local: a warning about that, still exit 1" "nonzero/yes/0" \
  "$(nonzero "$rc")/$(has "$out" 'CI_RUNNER is already local on acme/app although its routing is not in place')/$(called 'variable set')"

# ── Dry run ────────────────────────────────────────────────────────────────
echo "dry run"
adopt GH_CI_RUNNER=hosted -- --dry-run
record "ready, member missing, not local: reports both, writes nothing" "0/yes/yes/0/0" \
  "$rc/$(has "$out" 'would add acme/app to homefield-ci (dry run)')/$(has "$out" 'CI_RUNNER hosted -> local (dry run)')/$(called 'X PUT')/$(called 'variable set')"
adopt GH_WF="$work/wf-noguard" -- --dry-run
record "not ready: reports, exit 1, writes nothing" "nonzero/yes/0/0" "$(nonzero "$rc")/$(has "$out" 'routing: not ready')/$(called 'X PUT')/$(called 'variable set')"
adopt GH_CI_RUNNER=local -- --dry-run
record "already local: nothing written" "0/0/0" "$rc/$(called 'X PUT')/$(called 'variable set')"
record "...and the dry run says so up front" "yes" "$(has "$out" 'dry run: nothing will be changed')"
adopt GH_GROUPS="$work/groups-all" -- --dry-run
record "no gh call of a write kind in any dry run" "0" "$(called_any 'X POST' 'X PUT' 'X PATCH' 'X DELETE' 'variable set' 'run cancel' 'run rerun')"

# ── Cache keys ─────────────────────────────────────────────────────────────
echo "cache keys"
adopt GH_WF="$work/wf-cache" --
record "keys with runner.os and no runner.arch: file:line, for key and restore-keys" "yes/yes/yes" \
  "$(has "$out" "ci.yml:${cache_line_key}: \${{ runner.os }}-npm-")/$(has "$out" "ci.yml:${cache_line_restore}: \${{ runner.os }}-npm-")/$(has "$out" 'docs/adopting.md, step 4')"
record "...only those two, a warning each, and it does not stop the adoption" "2/0" "$(printf '%s\n' "$out" | grep -c 'ci.yml:[0-9]*: ')/$rc"
record "...and not the key in a workflow without routed jobs" "no" "$(has "$out" 'nightly.yml')"
adopt --
record "keys that carry runner.arch: not reported" "yes/no" "$(has "$out" 'cache keys: none found')/$(has "$out" 'warning: cache keys')"

# ── tools/adopt.py on its own ──────────────────────────────────────────────
echo "tools/adopt.py"
shapes="$work/shapes"
mkdir -p "$shapes"
cat >"$shapes/a.yml" <<'EOF'
on: pull_request
jobs:
  one:
    steps:
      # - uses: x/homefield/routing-guard@v0.3.0   (commented out)
      - uses: i2Dev-com/homefield/routing-guard@v0.3.0
        with:
          jobs: a.yml:one a.yml:two
  two:
    steps:
      - name: Guard
        with:
          label: "acme-ci"
          jobs: "a.yml:one, a.yml:two"
        uses: 'i2Dev-com/homefield/routing-guard@v0.3.0'
      - uses: actions/checkout@v5
        with:
          jobs: not-a-guard
  three:
    steps:
      - name: Guard, comments in and after the block
        uses: i2Dev-com/homefield/routing-guard@v0.3.0 # pinned
        with:
          jobs: |-
            a.yml:one

          # a comment at the key's depth ends the scalar
      - run: echo done
EOF
printf 'on: [push, pull_request]\r\njobs:\r\n  j:\r\n    steps:\r\n      - uses: i2dev-com/homefield/routing-guard@v0.3.0\r\n        with:\r\n          jobs: |\r\n            b.yml:j\r\n' >"$shapes/b.yaml"
printf 'jobs:\n  j:\n    steps:\n      - uses: o/r/routing-guard@v0.3.0\n' >"$shapes/c.yml"
echo "not a workflow" >"$shapes/d.txt"
got="$(python3 -I "$ROOT/tools/adopt.py" guards "$shapes")"
want="$(printf 'a.yml:6\tok\thomefield-ci\t-\t-\tpull_request\thosted\tubuntu-latest\tarm64\ta.yml:one a.yml:two\na.yml:15\tok\tacme-ci\t-\t-\tpull_request\thosted\tubuntu-latest\tarm64\ta.yml:one a.yml:two\na.yml:22\tok\thomefield-ci\t-\t-\tpull_request\thosted\tubuntu-latest\tarm64\ta.yml:one\nb.yaml:5\tok\thomefield-ci\t-\t-\tpull_request\thosted\tubuntu-latest\tarm64\tb.yml:j\nc.yml:4\tsource\thomefield-ci\tthe routing-guard step at c.yml:4 uses o/r/routing-guard@v0.3.0, but adopt recognizes i2Dev-com/homefield/routing-guard@v0.3.0, the release this copy of homefield checks with, or a full commit SHA (docs/adopting.md, step 3)\t-\tpull_request\thosted\tubuntu-latest\tarm64\t')"
record "guards: shapes of the step (block, inline, quoted, uses after with, CRLF, none, another action)" "$want" "$got"
got="$(python3 -I "$ROOT/tools/adopt.py" guards "$work/wf-i2dev")"
want="$(printf 'ci-checks.yml:9\tok\thomefield-ci\t-\tci.yml:5: the pull_request trigger has branches, paths-ignore filters;ci.yml:19: job checks, which calls ci-checks.yml, has an if: condition\tpull_request\thosted\tubuntu-latest\tarm64\tci-checks.yml:lint ci-checks.yml:test')"
record "guards: the columns of a guard behind a caller (status, blocking, warnings joined by ;)" "$want" "$got"
mkdir -p "$work/opts-shape"
cat >"$work/opts-shape/ci.yml" <<'EOF'
on: pull_request
jobs:
  j:
    steps:
      - uses: i2Dev-com/homefield/routing-guard@v0.3.0
        with:
          jobs: ci.yml:j
          events: |
            push
            schedule
          dependabot: local
          fallback: "ubuntu-24.04-arm"
      - uses: i2Dev-com/homefield/routing-guard@v0.3.0
        with:
          jobs: ci.yml:j
          events: push, workflow_dispatch # trailing
      - uses: i2Dev-com/homefield/routing-guard@v0.3.0
        with:
          jobs: ci.yml:j
          events: ''
EOF
got="$(python3 -I "$ROOT/tools/adopt.py" guards "$work/opts-shape" | cut -f1,2,6-)"
want="$(printf 'ci.yml:5\tok\tpush schedule\tlocal\tubuntu-24.04-arm\tarm64\tci.yml:j\nci.yml:13\tok\tpush workflow_dispatch\thosted\tubuntu-latest\tarm64\tci.yml:j\nci.yml:17\tok\t-\thosted\tubuntu-latest\tarm64\tci.yml:j')"
record "guards: events, dependabot and fallback columns (block, inline, empty)" "$want" "$got"
mkdir -p "$work/arch-shape"
cat >"$work/arch-shape/ci.yml" <<'EOF'
on: pull_request
jobs:
  j:
    steps:
      - uses: i2Dev-com/homefield/routing-guard@v0.3.0
        with:
          jobs: ci.yml:j
          arch: x64
      - uses: i2Dev-com/homefield/routing-guard@v0.3.0
        with:
          jobs: ci.yml:j
          arch: "arm64" # the VM
      - uses: i2Dev-com/homefield/routing-guard@v0.3.0
        with:
          jobs: ci.yml:j
          arch: ''
      - uses: i2Dev-com/homefield/routing-guard@v0.3.0
        with:
          jobs: ci.yml:j
EOF
got="$(python3 -I "$ROOT/tools/adopt.py" guards "$work/arch-shape" | cut -f1,9)"
want="$(printf 'ci.yml:5\tx64\nci.yml:9\tarm64\nci.yml:13\t-\nci.yml:17\tarm64')"
record "guards: the arch column (set, quoted with a comment, empty, absent)" "$want" "$got"
mkdir -p "$work/no-on"
printf 'jobs:\n  j:\n    steps:\n      - uses: i2Dev-com/homefield/routing-guard@v0.3.0\n' >"$work/no-on/ci.yml"
record "guards: a workflow whose on: cannot be read is blocked, not trusted" "blocked/yes" \
  "$(python3 -I "$ROOT/tools/adopt.py" guards "$work/no-on" | cut -f2)/$(has "$(python3 -I "$ROOT/tools/adopt.py" guards "$work/no-on" | cut -f4)" 'could not read the on: of ci.yml')"
mkdir -p "$work/refs-shape"
{
  printf 'on: pull_request\njobs:\n  j:\n    steps:\n'
  for ref in v0.3.0 v0.4.0 v10.20.30 v3 v0.1 v0.3.0-rc1 v0.3.0.1 V0.1.0 main "$sha40"; do
    printf '      - uses: i2Dev-com/homefield/routing-guard@%s\n        with:\n          jobs: ci.yml:j\n' "$ref"
  done
} >"$work/refs-shape/ci.yml"
got="$(python3 -I "$ROOT/tools/adopt.py" guards "$work/refs-shape" | cut -f2 | tr '\n' ' ')"
record "guards: this release and a full SHA are guards; other releases, a major, a minor, a suffix, another case and a branch are not" "ok source source source source source source source source ok " "$got"
record "guards: a directory with no workflow files has none" "" "$(mkdir -p "$work/empty" && python3 -I "$ROOT/tools/adopt.py" guards "$work/empty")"
record "guards: the text of a run: script has no steps" "" "$(python3 -I "$ROOT/tools/adopt.py" guards "$work/wf-heredoc")"
got="$(python3 -I "$ROOT/tools/adopt.py" guards "$work/wf-emptylabel" | cut -f2,3)"
record "guards: label: set to nothing is source, with label -" "$(printf 'source\t-')" "$got"
got="$(python3 -I "$ROOT/tools/adopt.py" guards "$work/wf-flowwith" | cut -f2)"
record "guards: a one-line with: is source" "source" "$got"

cat >"$shapes/e.yml" <<'EOF'
steps:
  - uses: actions/cache@v5
    with:
      key: ${{ runner.os }}-a
  - uses: actions/cache@v5
    with:
      key: ${{ runner.os }}-${{ runner.arch }}-b
  - uses: actions/cache@v5
    with:
      # key: ${{ runner.os }}-commented
      key: "${{ runner.os }}-c" # trailing
      restore-keys: |
        ${{ runner.os }}-d
        ${{ runner.arch }}-${{ runner.os }}-e
  - run: echo key ${{ runner.os }}
  - uses: other/action@v1
    with:
      other-key: ${{ runner.os }}
EOF
rm -f "$shapes/a.yml" "$shapes/b.yaml" "$shapes/c.yml"
got="$(python3 -I "$ROOT/tools/adopt.py" cache-keys "$shapes")"
want="$(printf 'e.yml:4: %s-a\ne.yml:11: "%s-c"\ne.yml:13: %s-d' "$os_key" "$os_key" "$os_key")"
record "cache-keys: key and restore-keys with runner.os only, not comments or other keys" "$want" "$got"
record "guard-snippet: placeholder, and a label only when it is not the default" "yes/yes/no" \
  "$(has "$(python3 -I "$ROOT/tools/adopt.py" guard-snippet --label acme-ci)" '          label: acme-ci')/$(has "$(python3 -I "$ROOT/tools/adopt.py" guard-snippet)" 'ci.yml:<job-id>')/$(has "$(python3 -I "$ROOT/tools/adopt.py" guard-snippet)" 'label:')"
snippet="$(python3 -I "$ROOT/tools/adopt.py" guard-snippet --events 'schedule, push' --dependabot local --fallback ubuntu-24.04-arm)"
record "guard-snippet: events, dependabot and fallback when they are not the defaults" "yes/yes/yes" \
  "$(has "$snippet" '          events: schedule, push')/$(has "$snippet" '          dependabot: local')/$(has "$snippet" '          fallback: ubuntu-24.04-arm')"
snippet="$(python3 -I "$ROOT/tools/adopt.py" guard-snippet --events pull_request --dependabot hosted --fallback ubuntu-latest)"
record "guard-snippet: ...and none of them when they are" "no/no/no" \
  "$(has "$snippet" 'events:')/$(has "$snippet" 'dependabot:')/$(has "$snippet" 'fallback:')"
record "quote: spaces and slashes are encoded" "a%20b%2Fc.yml" "$(python3 -I "$ROOT/tools/adopt.py" quote 'a b/c.yml')"

# ── The docs say what the tool prints ──────────────────────────────────────
echo "docs"
adopting="$(cat "$ROOT/docs/adopting.md")"
readme="$(cat "$ROOT/README.md")"
record "docs/adopting.md has the canonical expression" "yes" "$(has "$adopting" "runs-on: $expr")"
record "README.md has the canonical expression" "yes" "$(has "$readme" "runs-on: $expr")"
record "docs/adopting.md shows the expression for events push" "yes" "$(has "$adopting" "runs-on: $expr_push")"
pinned="$(python3 -B -I -c 'import sys; sys.path.insert(0, sys.argv[1]); import adopt; print(adopt.ACTION)' "$ROOT/tools")"
record "docs/adopting.md pins the same routing-guard as the snippet" "yes" "$(has "$adopting" "uses: $pinned")"
record "README.md pins the same routing-guard as the snippet" "yes" "$(has "$readme" "uses: $pinned")"

summary
