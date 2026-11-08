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
state="${CALLS%/*}" # the test directory: where branch and pr_body state lives
# GH_HANG=<text>: the first call whose arguments hold the text records HUNG
# (what a test waits for before it signals) and then hangs for GH_HANG_SECS, as
# a gh waiting on the network does; it carries on as usual if it is not killed.
# GH_HANG2 is a second one (records HUNG2). GH_HANG_SLEEP is the real sleep,
# not the recording stub.
all="$*"
hang() {
  [ -n "$1" ] && [ ! -f "$state/hung$2" ] || return 0
  case "$all" in
    *"$1"*)
      : >"$state/hung$2"
      echo "HUNG$2" >>"$CALLS"
      "$GH_HANG_SLEEP" "$3"
      ;;
  esac
}
hang "${GH_HANG:-}" "" "${GH_HANG_SECS:-30}"
hang "${GH_HANG2:-}" 2 "${GH_HANG2_SECS:-30}"
case "$*" in
  # gh auth status (gh_active_account): GH_AUTH is "login|scopes" the way the
  # real gh answers, empty when nobody is logged in, GH_AUTH_FAIL a gh that
  # cannot answer at all.
  "auth status"*)
    if [ -n "${GH_AUTH_FAIL:-}" ]; then echo "gh: (github.com) could not be asked" >&2; exit 1; fi
    # Like the real gh with --jq applied: the scopes' spaces are gone
    # (gh_active_account's gsub strips them), so the helper's `,scope,`
    # match runs on the same shape the real gh produces.
    if [ -n "${GH_AUTH:-}" ]; then printf '%s\n' "$GH_AUTH" | tr -d ' '; fi
    ;;
  "variable get CI_RUNNER"*)
    if [ -n "${GH_CI_RUNNER:-}" ]; then echo "$GH_CI_RUNNER"; else echo "variable not found" >&2; exit 1; fi
    ;;
  "variable set"*)
    n=$(($(cat "$state/varset-n" 2>/dev/null || echo 0) + 1))
    echo "$n" >"$state/varset-n"
    if [ -n "${GH_VARSET_FAIL:-}" ]; then echo "gh: HTTP 422 (variable set)" >&2; exit 1; fi
    # GH_VARSET_FAIL_FIRST=<n>: the first n variable set calls fail, the rest
    # succeed — how a route across repositories fails on some, not all.
    if [ -n "${GH_VARSET_FAIL_FIRST:-}" ] && [ "$n" -le "$GH_VARSET_FAIL_FIRST" ]; then echo "gh: HTTP 422 (variable set $n)" >&2; exit 1; fi
    ;;
  # route: the status of a run being cancelled (GH_RUN_STATUS), and the cancel.
  "run view"*)
    if [ -n "${GH_RUNVIEW_FAIL:-}" ]; then echo "gh: HTTP 502" >&2; exit 1; fi
    echo "${GH_RUN_STATUS:-completed}"
    ;;
  "run cancel"*)
    if [ -n "${GH_CANCEL_FAIL:-}" ]; then echo "gh: HTTP 409" >&2; exit 1; fi
    ;;
  # adopt --verify: the latest pull-request run (GH_RUNLIST, a JSON array),
  # the re-run, the jobs of the run (GH_JOBS is a directory of pages as
  # `gh api --paginate` prints them, one file per call: 1, 2, ...; the last
  # one repeats) and the run object (GH_RUN).
  "run list"*)
    if [ -n "${GH_RUNLIST_FAIL:-}" ]; then echo "gh: HTTP 500" >&2; exit 1; fi
    # --limit N: the real gh fetches at most N runs. Slicing here is what keeps
    # the guard-skip cases honest: a fixture with more rows than the limit must
    # not leak rows the real call would never see.
    limit="$(printf '%s' "$*" | sed -n 's/.*--limit \([0-9]*\).*/\1/p')"
    if [ -n "$limit" ]; then
      jq -c ".[:$limit]" "$GH_RUNLIST" 2>/dev/null || cat "$GH_RUNLIST"
    else
      cat "$GH_RUNLIST"
    fi
    ;;
  "run rerun"*)
    if [ -n "${GH_RERUN_FAIL:-}" ]; then echo "gh: HTTP 403: cannot re-run this workflow" >&2; exit 1; fi
    ;;
  "api "*"repos/"*"/actions/runs/"*"/jobs"*)
    if [ -n "${GH_JOBS_FAIL:-}" ]; then echo "gh: HTTP 502" >&2; exit 1; fi
    n=$(($(cat "$state/jobs-n" 2>/dev/null || echo 0) + 1))
    echo "$n" >"$state/jobs-n"
    while [ ! -f "$GH_JOBS/$n" ] && [ "$n" -gt 1 ]; do n=$((n - 1)); done
    cat "$GH_JOBS/$n"
    ;;
  "api repos/"*"/actions/runs/"*)
    if [ -n "${GH_RUN_FAIL:-}" ]; then echo "gh: HTTP 404" >&2; exit 1; fi
    cat "$GH_RUN"
    ;;
  *"-X PUT"*)
    if [ -n "${GH_PUT_404:-}" ]; then echo "gh: Not Found (HTTP 404)" >&2; exit 1; fi
    if [ -n "${GH_PUT_FAIL:-}" ]; then echo "gh: HTTP 403" >&2; exit 1; fi
    # a Contents PUT records its JSON body, so a test can check the sha the
    # update carried (none means create mode).
    in="" prev="" cname=""
    for a in "$@"; do
      [ "$prev" = "--input" ] && in="$a"
      case "$a" in */contents/.github/workflows/*) cname="${a##*/}" ;; esac
      prev="$a"
    done
    if [ -n "$in" ] && [ -n "$cname" ]; then cat "$in" >"$state/put-$cname.json"; fi
    ;;
  # route: the active-runs listing (stuck_runs). GH_RUN is what the call's
  # --jq prints: one run id per line. A run has one status, so the in_progress
  # listing answers GH_RUN_IN_PROGRESS (empty: nothing) unless set.
  *"actions/runs?status="*)
    if [ -n "${GH_RUN_FAIL:-}" ]; then echo "gh: HTTP 500" >&2; exit 1; fi
    case "$*" in
      *"status=queued"*) cat "$GH_RUN" ;;
      *"status=in_progress"*) cat "${GH_RUN_IN_PROGRESS:-/dev/null}" ;;
    esac
    ;;
  *"/contents/.github/workflows/"*)
    for a in "$@"; do case "$a" in repos/*/contents/.github/workflows/*) name="${a##*/}" ;; esac; done
    name="$(printf '%s' "$name" | sed 's/%20/ /g')"
    wfdir="$GH_WF"
    if [ -f "$state/pr_merged" ] && [ -n "${GH_WF_MERGED:-}" ]; then wfdir="$GH_WF_MERGED"; fi
    # Only a GET reaches this endpoint: like real gh, parameters without
    # --method GET switch the call to POST, which answers nothing here.
    case "$*" in *"-X GET"*) ;; *) echo "gh: HTTP 405" >&2; exit 1 ;; esac
    jq=""
    for a in "$@"; do [ "$a" = "--jq" ] && jq=1; done
    if [ -n "$jq" ]; then
      # the sha lookup of adopt --setup: GH_EXISTING_SHA is the file on the
      # branch, its absence is the 404 of a file that does not exist yet.
      if [ -n "${GH_EXISTING_SHA:-}" ]; then printf '%s\n' "$GH_EXISTING_SHA"; else echo "gh: Not Found (HTTP 404)" >&2; exit 1; fi
    else
      cat "$wfdir/$name"
    fi
    ;;
  *"/contents/.github/workflows"*)
    wfdir="${GH_WF:-/nonexistent}"
    if [ -f "$state/pr_merged" ] && [ -n "${GH_WF_MERGED:-}" ]; then wfdir="$GH_WF_MERGED"; fi
    if [ ! -d "$wfdir" ]; then echo "gh: Not Found (HTTP 404)" >&2; exit 1; fi
    if [ -n "${GH_WF_FAIL:-}" ]; then echo "gh: Server Error (HTTP 500)" >&2; exit 1; fi
    for f in "$wfdir"/*; do if [ -f "$f" ]; then basename "$f"; fi; done
    ;;
  *"runner-groups/"*"/repositories?"*)
    if [ -n "${GH_MEMBERS_FAIL:-}" ]; then echo "gh: HTTP 500" >&2; exit 1; fi
    cat "$GH_MEMBERS"
    ;;
  *runner-groups*)
    if [ -n "${GH_LIST_FAIL:-}" ]; then echo '{"message":"Must have admin rights"}'; echo "gh: HTTP 403" >&2; exit 1; fi
    cat "$GH_GROUPS"
    ;;
  # --setup: reading the default branch, branch existence (flat names), branch
  # creation and removal, and opening the pull request (its body lands in
  # $state/pr_body for the assertions).
  */commits/*)
    echo cafe0001
    ;;
  *"/git/ref/heads/"*)
    br=""
    for a in "$@"; do case "$a" in */git/ref/heads/*) br="${a##*/git/ref/heads/}" ;; esac; done
    if [ -n "$br" ] && [ -f "$state/branch-$(printf '%s' "$br" | tr / _)" ]; then
      echo 1789abcd
    else
      echo "gh: Not Found (HTTP 404)" >&2; exit 1
    fi
    ;;
  *"/git/refs/heads/"*)
    for a in "$@"; do
      case "$a" in
        */git/refs/heads/*)
          f="$state/branch-$(printf '%s' "${a##*/git/refs/heads/}" | tr / _)"
          if [ ! -f "$f" ]; then echo "gh: Not Found (HTTP 404)" >&2; exit 1; fi
          rm -f "$f"
          ;;
      esac
    done
    ;;
  *"POST repos/"*"/git/refs"*)
    if [ -n "${GH_REFS_FAIL:-}" ]; then echo "gh: HTTP 422" >&2; exit 1; fi
    for a in "$@"; do
      case "$a" in ref=refs/heads/*) : >"$state/branch-$(printf '%s' "${a#ref=refs/heads/}" | tr / _)" ;; esac
    done
    echo 1789abcd
    ;;
  *"POST repos/"*"/pulls"*)
    : >"$state/pr_body"
    for a in "$@"; do
      case "$a" in body=*) printf '%s\n' "${a#body=}" >>"$state/pr_body" ;; esac
    done
    echo "${GH_PR_URL:-https://github.com/acme/app/pull/77}"
    ;;
  # adopt --setup --wait reading the pull request: each read answers with the
  # next word of the file GH_PR_SEQ (the last one repeats): open, closed
  # (without a merge), merged, fail, or any other word as it is. The first
  # merged answer is remembered, so that GH_WF_MERGED can be served after it.
  *"/pulls/"*)
    n=0
    if [ -f "$state/pr_polls" ]; then n="$(cat "$state/pr_polls")"; fi
    n=$((n + 1))
    echo "$n" >"$state/pr_polls"
    word="$(sed -n "${n}p" "$GH_PR_SEQ")"
    if [ -z "$word" ]; then word="$(sed -n '$p' "$GH_PR_SEQ")"; fi
    case "$word" in
      open) printf 'open\t-\n' ;;
      closed) printf 'closed\t-\n' ;;
      merged) : >"$state/pr_merged"; printf 'closed\t2026-11-01T10:00:00Z\n' ;;
      fail) echo "gh: HTTP 502" >&2; exit 1 ;;
      *) printf '%s\n' "$word" ;;
    esac
    ;;
  "api repos/"*)
    if [ -n "${GH_REPO_FAIL:-}" ]; then echo "gh: Not Found (HTTP 404)" >&2; exit 1; fi
    printf '%s\n' "${GH_REPO:-true	555	main	Organization}"
    ;;
esac
EOF
chmod +x "$work/gh"
for t in awk basename cat dirname git grep head ls mkdir mktemp rm sed sleep tr wc jq; do [ -x "$stubs/$t" ] || ln -sf "$(command -v "$t")" "$stubs/$t"; done
# mktemp -d without a template puts the directory in TMPDIR on Linux but not on
# macOS; the explicit template makes both land in $TMPDIR, where a test can
# look for what a run left behind.
real_mktemp="$(command -v mktemp)"
rm -f "$stubs/mktemp"
cat >"$stubs/mktemp" <<MKTEMP
#!/bin/sh
if [ "\$*" = "-d" ]; then exec "$real_mktemp" -d "\${TMPDIR:-/tmp}/adopt.XXXXXX"; fi
exec "$real_mktemp" "\$@"
MKTEMP
chmod +x "$stubs/mktemp"
# sleep only records itself, so that no test waits; SLEEP_REAL=1 makes it a real
# sleep, for the one test that has to interrupt a wait in progress.
real_sleep="$(command -v sleep)"
rm -f "$stubs/sleep"
cat >"$stubs/sleep" <<SLEEP
#!/bin/sh
echo "sleep \$*" >>"\$CALLS"
if [ -n "\${SLEEP_REAL:-}" ]; then exec "$real_sleep" "\$@"; fi
SLEEP
chmod +x "$stubs/sleep"
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
expr_simple="$(python3 "$ROOT/routing-guard/routing_guard.py" --print-expression --mode simple)"
expr_acme_simple="$(python3 "$ROOT/routing-guard/routing_guard.py" --print-expression --mode simple --label acme-ci)"
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
guard() { guard_uses i2Dev-com/homefield/routing-guard@v0.5.2 "$@"; }
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
  emit_job lint ubuntu-latest "$(printf '      - name: Routing guard\n        uses: i2Dev-com/homefield/routing-guard@v0.5.2\n        with:\n          jobs: '"''"'')"
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
action="i2Dev-com/homefield/routing-guard@v0.5.2"
sha40="0123456789abcdef0123456789abcdef01234567"
wf_guard wf-src-other 'on: [pull_request]' other-org/homefield/routing-guard@v0.5.0
wf_guard wf-src-v1 'on: [pull_request]' i2Dev-com/homefield/routing-guard@v1
wf_guard wf-src-v3 'on: [pull_request]' i2Dev-com/homefield/routing-guard@v3
wf_guard wf-src-minor 'on: [pull_request]' i2Dev-com/homefield/routing-guard@v0.1
wf_guard wf-src-later 'on: [pull_request]' i2Dev-com/homefield/routing-guard@v0.4.2
wf_guard wf-src-suffix 'on: [pull_request]' i2Dev-com/homefield/routing-guard@v0.5.2-rc1
wf_guard wf-src-main 'on: [pull_request]' i2Dev-com/homefield/routing-guard@main
wf_guard wf-src-short 'on: [pull_request]' i2Dev-com/homefield/routing-guard@${sha40%?}
wf_guard wf-src-sha 'on: [pull_request]' "i2Dev-com/homefield/routing-guard@${sha40}"
wf_guard wf-src-quoted 'on: [pull_request]' "'${action}'"
wf_guard wf-src-dquoted 'on: [pull_request]' "\"${action}\""
wf_guard wf-src-case 'on: [pull_request]' I2DEV-COM/HomeField/routing-guard@v0.5.2
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
  # The suites exercise this checkout at its own RELEASE, which is the
  # release that carries --mode: simple mode passes the threshold. A case
  # asking for the refusal passes a higher one (HOMEFIELD_MODE_RELEASE= is
  # empty and would fall back to the code's own threshold, which passes).
  # shellcheck disable=SC2016  # the -c script is expanded by the inner bash
  out="$(env -i HOME="$work" PATH="$stubs" TMPDIR="$work/tmp" CALLS="$calls" HOMEFIELD_SOURCE_ONLY=1 \
    HOMEFIELD_MODE_RELEASE="${HOMEFIELD_MODE_RELEASE:-v0.5.2}" "${envs[@]+"${envs[@]}"}" \
    "$BASH" -c '. "$1"; shift; "$@"' _ "$ROOT/bin/homefield" "$@" 2>&1 </dev/null)"
  rc=$?
}
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

# route <env...> -- <route args>: a cmd_route run with the stuck-run fixtures:
# GH_RUN is what `--jq '.workflow_runs[].id'` prints (run 9001 is active) and
# the GH_JOBS page is what the jobs --jq prints (job 551 of it is queued on the
# label), so run 9001 is stuck. An empty page means nothing is stuck.
route() {
  local envs=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do
    envs+=("$1")
    shift
  done
  shift
  rm -f "$work/jobs-n" "$work/varset-n"
  run_fn GH_RUN="$work/route-runs" GH_JOBS="$work/route-jobs" \
    "${envs[@]+"${envs[@]}"}" -- cmd_route "$@"
}

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
record "...the simple expression is printed (no guard yet: simple mode)" "yes" "$(has "$out" "runs-on: $expr_simple")"
record "...and the guard step, with the jobs that are routed" "yes/yes/yes" \
  "$(has "$out" 'uses: i2Dev-com/homefield/routing-guard@v0.5.2')/$(has "$out" '            ci.yml:lint')/$(has "$out" '            ci.yml:test')"
record "...the default label is not written into the guard" "no" "$(has "$out" 'label: homefield-ci')"
record "...and the last line says to merge first" "yes" "$(has "$out" 'not switched: merge the routing first, then run homefield adopt again')"
adopt GH_WF="$work/wf-noguard" -- --guards
record "...with --guards: the guarded expression is printed instead" "yes" "$(has "$out" "runs-on: $expr")"

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
record "snippets carry the chosen label in the expression and the guard" "yes/yes" "$(has "$out" "runs-on: $expr_acme_simple")/$(has "$out" '          label: acme-ci')"

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
record "no guard yet, --events/--dependabot without --guards: refused (simple routes every event)" "nonzero/yes" \
  "$(nonzero "$rc")/$(has "$out" 'have no effect in simple mode')"
adopt GH_WF="$work/wf-noguard" -- --events push
record "...either flag alone is refused too" "nonzero/yes/0" \
  "$(nonzero "$rc")/$(has "$out" 'have no effect in simple mode')/$(called 'variable set')"
adopt GH_WF="$work/wf-noguard" -- --dependabot local
record "...dependabot alone likewise" "nonzero/yes" \
  "$(nonzero "$rc")/$(has "$out" 'have no effect in simple mode')"
adopt GH_WF="$work/wf-noguard" -- --guards --events 'push,schedule' --dependabot local --fallback ubuntu-24.04-arm
record "no guard yet with --guards: the expression and the snippet carry the options" "nonzero/yes/yes/yes/yes/no" \
  "$(nonzero "$rc")/$(has "$out" "runs-on: $expr_combo")/$(has "$out" '          events: push, schedule')/$(has "$out" '          dependabot: local')/$(has "$out" '          fallback: ubuntu-24.04-arm')/$(has "$out" 'label:')"
adopt GH_WF="$work/wf-noguard" -- --setup --events push
record "--setup with --events alone, no --guards: refused" "nonzero/yes/0" \
  "$(nonzero "$rc")/$(has "$out" 'have no effect in simple mode')/$(called 'X POST')"
adopt GH_WF="$work/wf-noguard" -- --setup --dependabot local
record "--setup with --dependabot alone: refused" "nonzero/yes/0" \
  "$(nonzero "$rc")/$(has "$out" 'have no effect in simple mode')/$(called 'X POST')"
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

# The same shape, with the stale guard carrying arch x64 instead: the refusal
# is adopt's (the VM is arm64), the step's own check passes, and the arm64
# guard's jobs are still the ones advised.
mkdir -p "$work/wf-arch-two"
{
  header
  emit_job lint "$expr_x64" "$(guard_opts ci.yml:lint 'arch: x64')"
  emit_job test "$expr" "$(guard ci.yml:test)"
} >"$work/wf-arch-two/ci.yml"
adopt GH_WF="$work/wf-arch-two" --
record "two guards, one on arch x64: not ready, with the arch refusal" "nonzero/yes/0" \
  "$(nonzero "$rc")/$(has "$out" 'uses arch x64, but adopt sets up an arm64 VM')/$(called 'variable set')"
record "...the arm64 guard's routed jobs are the ones advised" "yes/no" \
  "$(has "$out" '            ci.yml:test')/$(has "$out" '            ci.yml:lint')"

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
route_case "another repository's routing-guard: not a guard, and says what it uses" wf-src-other not "ci.yml:9 uses other-org/homefield/routing-guard@v0.5.0, but $recognizes"
route_case "@v1, a major only: not a guard" wf-src-v1 not "uses i2Dev-com/homefield/routing-guard@v1, but $recognizes"
route_case "@v3, a major only: not a guard" wf-src-v3 not "uses i2Dev-com/homefield/routing-guard@v3, but $recognizes"
route_case "@v0.1, a minor only: not a guard" wf-src-minor not "uses i2Dev-com/homefield/routing-guard@v0.1, but $recognizes"
route_case "@v0.5.0-rc1, a suffix: not a guard" wf-src-suffix not "uses i2Dev-com/homefield/routing-guard@v0.5.2-rc1, but $recognizes"
route_case "the current release, @v0.5.2: ready" wf-on-list ready "routing: ready, the guard passes and these jobs are routed: ci.yml:lint"
route_case "another exact release, @v0.4.2: not a guard, its rules may differ" wf-src-later not "uses i2Dev-com/homefield/routing-guard@v0.4.2, but $recognizes"
route_case "...and says to pin this release or install that one" wf-src-later not "v0.4.2 may have other rules: pin v0.5.2, or install homefield v0.4.2"
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

# ── Route ──────────────────────────────────────────────────────────────────
# The command across repositories: one failed repository warns and the rest
# go on, and the exit status is the aggregate.
echo "route"
mkdir -p "$work/route-jobs"
printf '9001\n' >"$work/route-runs"
printf '551\n' >"$work/route-jobs/1"
route -- local --repo acme/app --repo acme/other
record "two repositories, both switched to local, exit 0" "0/1/1" \
  "$rc/$(called 'variable set CI_RUNNER --repo acme/app --body local')/$(called 'variable set CI_RUNNER --repo acme/other --body local')"
route GH_VARSET_FAIL_FIRST=1 -- local --repo acme/app --repo acme/other
record "the first variable set fails: a warning naming the repo and the manual step" "nonzero/yes/yes" \
  "$(nonzero "$rc")/$(has "$out" 'acme/app: could not set CI_RUNNER to local')/$(has "$out" 'gh variable set CI_RUNNER --repo acme/app --body local')"
record "...and the second repository is still switched" "1" "$(called 'variable set CI_RUNNER --repo acme/other --body local')"
route GH_VARSET_FAIL_FIRST=2 -- local --repo acme/app --repo acme/other
record "both variable sets fail: two warnings, exit nonzero" "nonzero/2" \
  "$(nonzero "$rc")/$(printf '%s\n' "$out" | grep -c 'could not set CI_RUNNER')"
route GH_VARSET_FAIL=1 -- hosted --repo acme/app
record "a failed set on hosted: warned, and no stuck-run listing for that repo" "nonzero/yes/0" \
  "$(nonzero "$rc")/$(has "$out" 'acme/app: could not set CI_RUNNER to hosted')/$(called 'actions/runs?status=queued')"
route GH_RUN_FAIL=1 -- hosted --repo acme/app --repo acme/other
record "the stuck-run listing fails: a warning, and the next repository is listed" "nonzero/yes/1" \
  "$(nonzero "$rc")/$(has "$out" 'acme/app: could not list its runs with gh')/$(called 'variable set CI_RUNNER --repo acme/other --body hosted')"
route -- hosted --repo acme/app
record "a stuck run: cancelled and re-run, exit 0" "0/1/1/yes" \
  "$rc/$(called 'run cancel 9001')/$(called 'run rerun 9001')/$(has "$out" 'acme/app: run 9001 re-run')"
route -- hosted --repo acme/app --dry-run
record "a dry run: the stuck run is reported, nothing written" "0/yes/0" \
  "$rc/$(has "$out" 'run 9001 has jobs waiting for homefield-ci; would cancel and re-run it')/$(called_any 'run cancel' 'run rerun')"
route GH_CANCEL_FAIL=1 -- hosted --repo acme/app
record "the cancel fails: a warning naming the manual re-run, and no re-run call" "nonzero/yes/0" \
  "$(nonzero "$rc")/$(has "$out" 'run 9001: the cancel failed; re-run it yourself: gh run rerun 9001 --repo acme/app')/$(called 'run rerun')"
route GH_RUNVIEW_FAIL=1 -- hosted --repo acme/app
record "the status read fails: a warning, no re-run, exit nonzero" "nonzero/yes/0" \
  "$(nonzero "$rc")/$(has "$out" 'run 9001: could not read its status with gh')/$(called 'run rerun')"
route GH_RUN_STATUS=in_progress ROUTE_TRIES=2 ROUTE_INTERVAL=0 -- hosted --repo acme/app
record "the cancel does not land in a minute: said, with the manual re-run" "0/yes" \
  "$rc/$(has "$out" 'run 9001 is still in_progress after a minute; re-run it yourself: gh run rerun 9001 --repo acme/app')"
route GH_RERUN_FAIL=1 -- hosted --repo acme/app
record "the re-run is refused: a warning, exit nonzero" "nonzero/yes" \
  "$(nonzero "$rc")/$(has "$out" 'run 9001: the re-run was refused; run it yourself: gh run rerun 9001 --repo acme/app')"
printf '551\n' >"$work/route-jobs/1"
: >"$work/route-jobs/2"
printf '9001\n9002\n' >"$work/route-runs-alt"
route GH_RUN="$work/route-runs-alt" -- hosted --repo acme/app
record "two active runs, only the first stuck: one cancel and one re-run" "0/1/1" \
  "$rc/$(called 'run cancel 9001')/$(called 'run rerun 9001')"
record "...and the second run is not touched" "0" "$(called 'run cancel 9002')"
: >"$work/route-jobs/1"
route -- hosted --repo acme/app
record "nothing stuck: the switch is the whole job, exit 0" "0/1/0" \
  "$rc/$(called 'variable set CI_RUNNER --repo acme/app --body hosted')/$(called_any 'run cancel' 'run rerun')"

# ── Verify ─────────────────────────────────────────────────────────────────
# The re-run of the latest pull-request run, and the report of where its jobs
# ran. Fixtures: the run list and run object the stub serves, and directories
# of jobs pages (one file per call of the jobs endpoint, the last repeating).
echo "verify"
# vjob <name> <status> <conclusion|null> <runner|null> <attempt> <label>...
vjob() {
  local name="$1" status="$2" concl="$3" runner="$4" attempt="$5" labels="" l
  shift 5
  for l in "$@"; do labels="${labels:+$labels,}\"$l\""; done
  [ "$concl" = null ] || concl="\"$concl\""
  [ "$runner" = null ] || runner="\"$runner\""
  printf '{"name":"%s","status":"%s","conclusion":%s,"runner_name":%s,"run_attempt":%s,"labels":[%s]}' \
    "$name" "$status" "$concl" "$runner" "$attempt" "$labels"
}
# vpage <job>...: one page of the jobs endpoint.
vpage() {
  local sep="" j out=""
  for j in "$@"; do
    out="$out$sep$j"
    sep=","
  done
  printf '{"total_count":%d,"jobs":[%s]}\n' "$#" "$out"
}
vrun() { printf '[{"databaseId":%s,"status":"%s","url":"https://github.com/acme/app/actions/runs/%s","displayTitle":"Fix the thing"}]\n' "$1" "$2" "$1"; }
loc=(self-hosted Linux ARM64 homefield-ci)
vrun 9001 completed >"$work/runlist-done"
vrun 9001 in_progress >"$work/runlist-running"
echo '[]' >"$work/runlist-none"
echo '{"id":9001,"run_attempt":1,"status":"completed"}' >"$work/run-1"
echo '{"id":9001,"run_attempt":1,"status":"in_progress"}' >"$work/run-going"
echo '{"id":9001,"run_attempt":1}' >"$work/run-nostatus"
# a local run, jobs on two pages (as --paginate prints them)
mkdir -p "$work/jobs-local" "$work/jobs-mixed" "$work/jobs-stale" "$work/jobs-queued" "$work/jobs-failed" "$work/jobs-skip"
{
  vpage "$(vjob lint completed success homefield-1 2 "${loc[@]}")"
  vpage "$(vjob test completed success homefield-1 2 "${loc[@]}")"
} >"$work/jobs-local/1"
vpage "$(vjob lint completed success homefield-1 2 "${loc[@]}")" \
  "$(vjob e2e completed success "GitHub Actions 7" 2 ubuntu-latest)" >"$work/jobs-mixed/1"
# the previous attempt is all that is listed at first, then nothing, then the new one
vpage "$(vjob lint completed success "GitHub Actions 3" 1 ubuntu-latest)" >"$work/jobs-stale/1"
vpage >"$work/jobs-stale/2"
vpage "$(vjob lint completed success homefield-1 2 "${loc[@]}")" \
  "$(vjob lint completed success "GitHub Actions 3" 1 ubuntu-latest)" >"$work/jobs-stale/3"
vpage "$(vjob lint queued null null 2 "${loc[@]}")" \
  "$(vjob test completed success homefield-1 2 "${loc[@]}")" >"$work/jobs-queued/1"
vpage "$(vjob lint completed failure homefield-1 2 "${loc[@]}")" \
  "$(vjob test in_progress null homefield-1 2 "${loc[@]}")" >"$work/jobs-failed/1"
vpage "$(vjob lint completed skipped null 2 "${loc[@]}")" >"$work/jobs-skip/1"
# a job named by someone with an escape sequence in it; the label in another case
mkdir -p "$work/jobs-esc" "$work/jobs-chain" "$work/jobs-hostonly"
vpage "$(vjob 'red\u001b[31m' completed success homefield-1 2 self-hosted Linux ARM64 HomeField-CI)" >"$work/jobs-esc/1"
# a job that calls a reusable workflow after a hosted job it needs: only the
# hosted one is listed at first, the called workflow's job a poll later
vpage "$(vjob prep completed success "GitHub Actions 7" 2 ubuntu-latest)" >"$work/jobs-chain/1"
vpage "$(vjob prep completed success "GitHub Actions 7" 2 ubuntu-latest)" \
  "$(vjob 'call / lint' in_progress null homefield-1 2 "${loc[@]}")" >"$work/jobs-chain/2"
vpage "$(vjob e2e completed success "GitHub Actions 7" 2 ubuntu-latest)" >"$work/jobs-hostonly/1"

# verify <env...> -- <adopt args>: adopt with the re-run fixtures; no sleeping.
verify() {
  local envs=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do
    envs+=("$1")
    shift
  done
  shift
  rm -f "$work/jobs-n"
  adopt GH_RUNLIST="$work/runlist-done" GH_RUN="$work/run-1" GH_JOBS="$work/jobs-local" \
    ADOPT_VERIFY_INTERVAL=0 ADOPT_VERIFY_TRIES=5 "${envs[@]+"${envs[@]}"}" -- "$@"
}
# verify_tty <answer|EOF> <env...> -- <adopt args>: the same on a terminal,
# which types the answer.
verify_tty() {
  local answer="$1" envs=() in="/dev/null"
  shift
  while [ $# -gt 0 ] && [ "$1" != -- ]; do
    envs+=("$1")
    shift
  done
  shift
  if [ "$answer" != EOF ]; then
    printf '%s\n' "$answer" >"$work/answer"
    in="$work/answer"
  fi
  rm -f "$work/jobs-n"
  : >"$calls"
  # shellcheck disable=SC2016  # the -c script is expanded by the inner bash
  out="$(env -i HOME="$work" PATH="$stubs" TMPDIR="$work/tmp" CALLS="$calls" HOMEFIELD_SOURCE_ONLY=1 \
    GH_GROUPS="$work/groups-selected" GH_MEMBERS="$work/members-other" GH_WF="$work/wf-ready" \
    GH_RUNLIST="$work/runlist-done" GH_RUN="$work/run-1" GH_JOBS="$work/jobs-local" \
    ADOPT_VERIFY_INTERVAL=0 ADOPT_VERIFY_TRIES=5 "${envs[@]+"${envs[@]}"}" \
    "$BASH" -c '. "$1"; shift; have_terminal() { true; }; "$@"' _ "$ROOT/bin/homefield" cmd_adopt --repo acme/app "$@" 2>&1 <"$in")"
  rc=$?
}
rerun_n() { called '^gh run rerun'; }
runs_n() { called_any '^gh run ' 'actions/runs/'; }
ask='Re-run the latest pull-request run of acme/app (uses CI minutes) to confirm the local runner takes it? [y/N]'

verify -- --verify
record "--verify, every job local: exit 0, one local line per job" "0/yes/yes" \
  "$rc/$(has "$out" 'verify: lint: ran on the local runner homefield-1 (success)')/$(has "$out" 'verify: test: ran on the local runner homefield-1 (success)')"
record "...the latest pull-request run is listed (one run, as JSON, with its workflow name), then the run is read: once for its attempt, once with the jobs" "1/2" \
  "$(called '^gh run list --repo acme/app --event pull_request --limit 1 --json databaseId,status,url,displayTitle,workflowName')/$(called '^gh api repos/acme/app/actions/runs/9001$')"
record "...re-run exactly once, with that run's id" "1/1" "$(rerun_n)/$(called '^gh run rerun 9001 --repo acme/app$')"
record "...the jobs are read, paginated" "1" "$(called '^gh api --paginate repos/acme/app/actions/runs/9001/jobs')"
record "...the question is not asked, and the summary counts both jobs" "no/yes" \
  "$(has "$out" 'uses CI minutes')/$(has "$out" 'verify: 2 on the local runner, 0 on GitHub-hosted runners, 0 still waiting for a runner')"
record "...no warning about a hosted job, no advice about a failed one" "no/no" "$(has "$out" 'warning:')/$(has "$out" 'Job fails only on the local runner')"
record "...the re-run comes after the run was read, and the report ends adopt with only what is left by hand" "yes/yes/no" \
  "$(before "$(cat "$calls")" 'gh api repos/acme/app/actions/runs/9001' 'gh run rerun 9001')/$(has "$out" 'still by hand: add any tools the jobs lack, and note why a job stays hosted if you want to (docs/adopting.md, step 7)')/$(has "$out" 'steps 6 and 7')"

verify GH_CI_RUNNER=local -- --verify
record "...an already local CI_RUNNER is verified too, without writing the variable" "0/1/0" "$rc/$(rerun_n)/$(called 'variable set')"
verify GH_CI_RUNNER=hosted -- --verify
record "...a switch that just happened is verified after it" "1/1/yes" \
  "$(called 'variable set')/$(rerun_n)/$(before "$(cat "$calls")" 'variable set' 'gh run rerun')"

verify GH_JOBS="$work/jobs-mixed" -- --verify
record "a job on a hosted runner: reported as such, and warned about" "0/yes/yes/yes" \
  "$rc/$(has "$out" 'verify: lint: ran on the local runner homefield-1 (success)')/$(has "$out" 'verify: e2e: ran on a GitHub-hosted runner (GitHub Actions 7; labels ubuntu-latest)')/$(has "$out" 'warning: e2e did not run on the local runner')"
record "...only the hosted job is warned about, and the summary counts one of each" "1/yes" \
  "$(printf '%s\n' "$out" | grep -c 'warning: .* did not run on the local runner')/$(has "$out" 'verify: 1 on the local runner, 1 on GitHub-hosted runners')"

verify GH_RUN="$work/run-going" GH_JOBS="$work/jobs-chain" -- --verify
record "a run still going, only a hosted job listed at first: polls again and finds the called workflow's job" "0/2/yes/yes" \
  "$rc/$(called 'actions/runs/9001/jobs')/$(has "$out" 'verify: call / lint: is running on the local runner homefield-1 (in_progress)')/$(has "$out" 'verify: prep: ran on a GitHub-hosted runner')"
record "...the run is read at each poll, and the report says the run is unfinished and the list may grow" "3/yes" \
  "$(called '^gh api repos/acme/app/actions/runs/9001$')/$(has "$out" 'verify: the run is still in_progress: a job that starts only after others finish is not in this list yet; look at https://github.com/acme/app/actions/runs/9001')"
verify GH_RUN="$work/run-going" GH_JOBS="$work/jobs-hostonly" ADOPT_VERIFY_TRIES=3 -- --verify
record "a run still going, nothing local listed: keeps polling until the tries run out, then warns and says the run is unfinished" "3/yes/yes" \
  "$(called 'actions/runs/9001/jobs')/$(has "$out" 'warning: e2e did not run on the local runner')/$(has "$out" 'the run is still in_progress')"
verify GH_JOBS="$work/jobs-hostonly" ADOPT_VERIFY_TRIES=3 -- --verify
record "a finished run with nothing local: settles at once (no wait for jobs that cannot come), no unfinished-run line" "1/yes/no" \
  "$(called 'actions/runs/9001/jobs')/$(has "$out" 'warning: e2e did not run on the local runner')/$(has "$out" 'the run is still')"
verify -- --verify
record "a finished run, all local: no unfinished-run line" "no" "$(has "$out" 'the run is still')"
verify GH_RUN="$work/run-nostatus" -- --verify
record "a run object without a status: could not verify, adopt still exits 0" "0/yes/no" \
  "$rc/$(has "$out" 'could not verify: gh gave a run that this tool cannot read')/$(has "$out" 'verify: lint: ')"

verify GH_JOBS="$work/jobs-stale" -- --verify
record "jobs of the previous attempt are ignored until the new attempt is listed" "0/1/yes/no/3" \
  "$rc/$(printf '%s\n' "$out" | grep -c 'verify: lint: ')/$(has "$out" 'verify: lint: ran on the local runner homefield-1 (success)')/$(has "$out" 'GitHub-hosted runner (GitHub Actions 3')/$(called 'actions/runs/9001/jobs')"

verify GH_JOBS="$work/jobs-queued" ADOPT_VERIFY_TRIES=4 -- --verify
record "a job still queued when the tries run out: a waiting line pointing at the failure modes" "0/yes/yes" \
  "$rc/$(has "$out" 'verify: lint: still waiting for a runner (queued)')/$(has "$out" '"Failure modes" in docs/runbook.md')"
record "...polled once per try, and the job that has a runner is still reported" "4/yes/yes" \
  "$(called 'actions/runs/9001/jobs')/$(has "$out" 'verify: test: ran on the local runner')/$(has "$out" '1 still waiting for a runner')"

verify GH_JOBS="$work/jobs-failed" -- --verify
record "a job that failed on the local runner: said so, with the toolchain advice once" "0/yes/yes/1" \
  "$rc/$(has "$out" 'verify: lint: failed on the local runner homefield-1 (failure)')/$(has "$out" 'docs/adopting.md, step 6, item 2; docs/runbook.md, "Job fails only on the local runner"')/$(printf '%s\n' "$out" | grep -c 'Job fails only on the local runner')"
record "...a job that is still running on it is reported as running" "yes" "$(has "$out" 'verify: test: is running on the local runner homefield-1 (in_progress)')"
verify GH_JOBS="$work/jobs-skip" -- --verify
record "a skipped job (no runner needed): not reported as waiting" "0/yes/no" "$rc/$(has "$out" 'verify: lint: skipped without a runner')/$(has "$out" 'lint: still waiting')"

verify GH_JOBS="$work/jobs-esc" -- --verify
record "a job name with control characters is printed without them, and a label in another case is the routing label" "0/no/yes" \
  "$rc/$(has "$out" $'\033')/$(has "$out" 'verify: red?[31m: ran on the local runner homefield-1 (success)')"

verify GH_RUNLIST="$work/runlist-none" -- --verify
record "no pull-request run yet: said so, pointing at step 6, no re-run, no more reads" "0/yes/yes/0/0" \
  "$rc/$(has "$out" 'has no pull-request run yet')/$(has "$out" 'docs/adopting.md, step 6')/$(rerun_n)/$(called 'actions/runs/')"
record "...and the last line still sends you to steps 6 and 7" "yes" "$(has "$out" 'docs/adopting.md, steps 6 and 7')"
verify GH_RUNLIST="$work/runlist-running" -- --verify
record "a run still in progress: not re-run, with the command for later" "0/yes/yes/0" \
  "$rc/$(has "$out" 'run 9001 (Fix the thing) is still in_progress')/$(has "$out" 'gh run rerun 9001 --repo acme/app')/$(rerun_n)"

# The guard workflow's own run ("HomeField routing") is hosted by design: the
# newest pull-request run can be exactly that (the adopt --setup PR creates
# one, and if nothing else ran since it is the newest). Re-running it proves
# nothing and always ends in the hosted warning, which is noise (#166). The
# stub honors --limit, so these fixtures exercise exactly what a real gh
# returns for each fetch.
echo '[{"databaseId":7001,"status":"completed","url":"https://github.com/acme/app/actions/runs/7001","displayTitle":"Route CI jobs to the local HomeField runner","workflowName":"HomeField routing"}]' >"$work/runlist-guard"
verify GH_RUNLIST="$work/runlist-guard" -- --verify
record "the newest pull-request run is the guard's own: not re-run, said so, pointer to verify by hand" "0/0/yes/yes" \
  "$rc/$(rerun_n)/$(has "$out" 'the routing guard')/$(has "$out" 'Open a pull request on the repository')"
record "...it looked below the newest one before concluding (the wider fetch ran)" "1" \
  "$(called '^gh run list --repo acme/app --event pull_request --limit 15 --json databaseId,status,url,displayTitle,workflowName$')"
record "...no hosted warning from the guard's hosted job" "no" "$(has "$out" 'warning:')"
# A guard run newest, a real CI run below it: only the wider fetch can see the
# CI run, and it is the one re-run.
echo '[{"databaseId":7001,"status":"completed","url":"https://github.com/acme/app/actions/runs/7001","displayTitle":"Route CI jobs to the local HomeField runner","workflowName":"HomeField routing"},{"databaseId":9001,"status":"completed","url":"https://github.com/acme/app/actions/runs/9001","displayTitle":"Fix the thing","workflowName":"CI"}]' >"$work/runlist-guard-plus"
verify GH_RUNLIST="$work/runlist-guard-plus" -- --verify
record "the guard run first in the list: the CI run after it is the one re-run" "0/1/0/yes" \
  "$rc/$(called '^gh run rerun 9001 --repo acme/app$')/$(called '^gh run rerun 7001')/$(has "$out" 'verify: lint: ran on the local runner homefield-1 (success)')"
record "...exactly two run-list fetches: the wide one only after the newest was the guard's" "2/1" \
  "$(called '^gh run list --repo acme/app')/$(called '^gh run list --repo acme/app --event pull_request --limit 15')"
# A run without workflowName (an older gh): picked as before, no crash, and
# one fetch only (nothing looks like a guard run, so no wider fetch).
verify GH_RUNLIST="$work/runlist-done" -- --verify
record "a run list without workflowName fields: re-runs as before" "1" "$(rerun_n)"
record "...a single fetch: the wide one is not needed when the newest is not the guard's" "1" \
  "$(called '^gh run list --repo acme/app')"

verify -- --verify --no-verify
record "--verify with --no-verify: refused before anything is read" "nonzero/yes/0" "$(nonzero "$rc")/$(has "$out" '--verify and --no-verify contradict each other')/$(called gh)"
verify -- --no-verify --verify
record "...in either order" "nonzero/yes/0" "$(nonzero "$rc")/$(has "$out" '--verify and --no-verify contradict each other')/$(called gh)"
verify -- --no-verify
record "--no-verify: no run is listed, read or re-run, and nothing is said about it" "0/0/no/no" \
  "$rc/$(runs_n)/$(has "$out" 'gh run rerun')/$(has "$out" 'verify:')"
verify_tty y -- --no-verify
record "...also on a terminal: no question" "0/0/no" "$rc/$(runs_n)/$(has "$out" 'uses CI minutes')"

verify --
record "no terminal and no --verify: nothing asked, nothing re-run, the commands printed" "0/no/0/yes/yes" \
  "$rc/$(has "$out" 'uses CI minutes')/$(runs_n)/$(has "$out" '  gh run list --repo acme/app --event pull_request --limit 15')/$(has "$out" '  gh run rerun <run-id> --repo acme/app')"
record "...and the last line keeps the pointer to steps 6 and 7" "yes" "$(has "$out" 'docs/adopting.md, steps 6 and 7')"

verify_tty y --
record "on a terminal, y: the question is asked, and the run is verified" "0/yes/1/yes" \
  "$rc/$(has "$out" "$ask")/$(rerun_n)/$(has "$out" 'verify: lint: ran on the local runner homefield-1 (success)')"
verify_tty Y --
record "...Y too" "1" "$(rerun_n)"
verify_tty n --
record "on a terminal, n: no re-run, the commands printed" "0/0/yes/yes" "$rc/$(rerun_n)/$(has "$out" "$ask")/$(has "$out" '  gh run rerun <run-id> --repo acme/app')"
record "...nothing of the run was listed either" "0" "$(runs_n)"
verify_tty "" --
record "on a terminal, Enter alone: the default is no" "0/0/yes" "$rc/$(runs_n)/$(has "$out" "$ask")"
verify_tty EOF --
record "on a terminal, end of input: no" "0/0/yes" "$rc/$(runs_n)/$(has "$out" "$ask")"
verify_tty y -- --verify
record "--verify on a terminal: no question, verified" "no/1" "$(has "$out" 'uses CI minutes')/$(rerun_n)"

verify -- --verify --dry-run
record "--dry-run: nothing is listed or re-run, and it says why" "0/0/yes" "$rc/$(runs_n)/$(has "$out" 'verify: skipped (dry run)')"
verify_tty y GH_CI_RUNNER=local -- --dry-run
record "...no question on a terminal either, even when CI_RUNNER is local already" "0/no" "$(runs_n)/$(has "$out" 'uses CI minutes')"
verify -- --verify --no-switch
record "--no-switch: nothing is listed or re-run, and it says why" "0/0/yes" "$rc/$(runs_n)/$(has "$out" 'verify: skipped (--no-switch)')"
verify_tty y -- --no-switch
record "...no question on a terminal" "0/no" "$(runs_n)/$(has "$out" 'uses CI minutes')"
verify GH_CI_RUNNER=local -- --verify --no-switch
record "...an already local CI_RUNNER does not change that" "0" "$(runs_n)"
verify GH_WF="$work/wf-noguard" -- --verify
record "routing not ready: adopt stops before the switch and nothing is re-run" "nonzero/0" "$(nonzero "$rc")/$(runs_n)"

verify GH_RUNLIST_FAIL=1 -- --verify
record "gh cannot list the runs: could not verify, adopt still exits 0, nothing re-run" "0/yes/0" \
  "$rc/$(has "$out" 'warning: could not verify: gh could not list the runs of acme/app: gh: HTTP 500')/$(rerun_n)"
record "...so the last line sends you to steps 6 and 7" "yes" "$(has "$out" 'docs/adopting.md, steps 6 and 7')"
verify GH_RUN_FAIL=1 -- --verify
record "gh cannot read the run: could not verify, no re-run" "0/yes/0" "$rc/$(has "$out" 'could not verify: gh could not read run 9001')/$(rerun_n)"
verify GH_RERUN_FAIL=1 -- --verify
record "the re-run is refused: could not verify, with gh's reason" "0/yes/1/0" \
  "$rc/$(has "$out" 'could not verify: gh could not re-run run 9001: gh: HTTP 403')/$(rerun_n)/$(called 'actions/runs/9001/jobs')"
verify GH_JOBS_FAIL=1 -- --verify
record "the jobs cannot be listed: could not verify, adopt still exits 0" "0/yes/1" \
  "$rc/$(has "$out" 'could not verify: gh could not list the jobs of run 9001: gh: HTTP 502')/$(rerun_n)"
record "...so the last line sends you to steps 6 and 7" "yes" "$(has "$out" 'docs/adopting.md, steps 6 and 7')"
echo '{"id":9001}' >"$work/run-noattempt"
verify GH_RUN="$work/run-noattempt" -- --verify
record "a run object this tool cannot read: could not verify, no re-run" "0/yes/0" "$rc/$(has "$out" 'could not verify: gh gave a run that this tool cannot read')/$(rerun_n)"
mkdir -p "$work/jobs-garbage"
echo 'not json' >"$work/jobs-garbage/1"
verify GH_JOBS="$work/jobs-garbage" -- --verify
record "a list of jobs this tool cannot read: could not verify" "0/yes" "$rc/$(has "$out" 'could not verify: gh gave a list of jobs that this tool cannot read')"
mkdir -p "$work/jobs-none"
vpage >"$work/jobs-none/1"
verify GH_JOBS="$work/jobs-none" ADOPT_VERIFY_TRIES=3 -- --verify
record "no job of the new attempt ever listed: could not verify, naming the run" "0/yes/3" \
  "$rc/$(has "$out" 'could not verify: no job of the re-run (attempt 2) was listed in time')/$(called 'actions/runs/9001/jobs')"
record "...the downloaded and scratch files are removed afterwards" "0" "$(find "$work/tmp" -mindepth 1 | wc -l | tr -d ' ')"

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
      # - uses: x/homefield/routing-guard@v0.5.0   (commented out)
      - uses: i2Dev-com/homefield/routing-guard@v0.5.2
        with:
          jobs: a.yml:one a.yml:two
  two:
    steps:
      - name: Guard
        with:
          label: "acme-ci"
          jobs: "a.yml:one, a.yml:two"
        uses: 'i2Dev-com/homefield/routing-guard@v0.5.2'
      - uses: actions/checkout@v5
        with:
          jobs: not-a-guard
  three:
    steps:
      - name: Guard, comments in and after the block
        uses: i2Dev-com/homefield/routing-guard@v0.5.2 # pinned
        with:
          jobs: |-
            a.yml:one

          # a comment at the key's depth ends the scalar
      - run: echo done
EOF
printf 'on: [push, pull_request]\r\njobs:\r\n  j:\r\n    steps:\r\n      - uses: i2dev-com/homefield/routing-guard@v0.5.2\r\n        with:\r\n          jobs: |\r\n            b.yml:j\r\n' >"$shapes/b.yaml"
printf 'jobs:\n  j:\n    steps:\n      - uses: o/r/routing-guard@v0.5.0\n' >"$shapes/c.yml"
echo "not a workflow" >"$shapes/d.txt"
got="$(python3 -I "$ROOT/tools/adopt.py" guards "$shapes")"
want="$(printf 'a.yml:6\tok\thomefield-ci\t-\t-\tpull_request\thosted\tubuntu-latest\tarm64\tguards\ta.yml:one a.yml:two\na.yml:15\tok\tacme-ci\t-\t-\tpull_request\thosted\tubuntu-latest\tarm64\tguards\ta.yml:one a.yml:two\na.yml:22\tok\thomefield-ci\t-\t-\tpull_request\thosted\tubuntu-latest\tarm64\tguards\ta.yml:one\nb.yaml:5\tok\thomefield-ci\t-\t-\tpull_request\thosted\tubuntu-latest\tarm64\tguards\tb.yml:j\nc.yml:4\tsource\thomefield-ci\tthe routing-guard step at c.yml:4 uses o/r/routing-guard@v0.5.0, but adopt recognizes i2Dev-com/homefield/routing-guard@v0.5.2, the release this copy of homefield checks with, or a full commit SHA (docs/adopting.md, step 3)\t-\tpull_request\thosted\tubuntu-latest\tarm64\tguards\t')"
record "guards: shapes of the step (block, inline, quoted, uses after with, CRLF, none, another action)" "$want" "$got"
got="$(python3 -I "$ROOT/tools/adopt.py" guards "$work/wf-i2dev")"
want="$(printf 'ci-checks.yml:9\tok\thomefield-ci\t-\tci.yml:5: the pull_request trigger has branches, paths-ignore filters;ci.yml:19: job checks, which calls ci-checks.yml, has an if: condition\tpull_request\thosted\tubuntu-latest\tarm64\tguards\tci-checks.yml:lint ci-checks.yml:test')"
record "guards: the columns of a guard behind a caller (status, blocking, warnings joined by ;)" "$want" "$got"
mkdir -p "$work/opts-shape"
cat >"$work/opts-shape/ci.yml" <<'EOF'
on: pull_request
jobs:
  j:
    steps:
      - uses: i2Dev-com/homefield/routing-guard@v0.5.2
        with:
          jobs: ci.yml:j
          events: |
            push
            schedule
          dependabot: local
          fallback: "ubuntu-24.04-arm"
      - uses: i2Dev-com/homefield/routing-guard@v0.5.2
        with:
          jobs: ci.yml:j
          events: push, workflow_dispatch # trailing
      - uses: i2Dev-com/homefield/routing-guard@v0.5.2
        with:
          jobs: ci.yml:j
          events: ''
EOF
got="$(python3 -I "$ROOT/tools/adopt.py" guards "$work/opts-shape" | cut -f1,2,6-)"
want="$(printf 'ci.yml:5\tok\tpush schedule\tlocal\tubuntu-24.04-arm\tarm64\tguards\tci.yml:j\nci.yml:13\tok\tpush workflow_dispatch\thosted\tubuntu-latest\tarm64\tguards\tci.yml:j\nci.yml:17\tok\t-\thosted\tubuntu-latest\tarm64\tguards\tci.yml:j')"
record "guards: events, dependabot and fallback columns (block, inline, empty)" "$want" "$got"
mkdir -p "$work/arch-shape"
cat >"$work/arch-shape/ci.yml" <<'EOF'
on: pull_request
jobs:
  j:
    steps:
      - uses: i2Dev-com/homefield/routing-guard@v0.5.2
        with:
          jobs: ci.yml:j
          arch: x64
      - uses: i2Dev-com/homefield/routing-guard@v0.5.2
        with:
          jobs: ci.yml:j
          arch: "arm64" # the VM
      - uses: i2Dev-com/homefield/routing-guard@v0.5.2
        with:
          jobs: ci.yml:j
          arch: ''
      - uses: i2Dev-com/homefield/routing-guard@v0.5.2
        with:
          jobs: ci.yml:j
EOF
got="$(python3 -I "$ROOT/tools/adopt.py" guards "$work/arch-shape" | cut -f1,9)"
want="$(printf 'ci.yml:5\tx64\nci.yml:9\tarm64\nci.yml:13\t-\nci.yml:17\tarm64')"
record "guards: the arch column (set, quoted with a comment, empty, absent)" "$want" "$got"
mkdir -p "$work/no-on"
printf 'jobs:\n  j:\n    steps:\n      - uses: i2Dev-com/homefield/routing-guard@v0.5.2\n' >"$work/no-on/ci.yml"
record "guards: a workflow whose on: cannot be read is blocked, not trusted" "blocked/yes" \
  "$(python3 -I "$ROOT/tools/adopt.py" guards "$work/no-on" | cut -f2)/$(has "$(python3 -I "$ROOT/tools/adopt.py" guards "$work/no-on" | cut -f4)" 'could not read the on: of ci.yml')"
mkdir -p "$work/refs-shape"
{
  printf 'on: pull_request\njobs:\n  j:\n    steps:\n'
  for ref in v0.5.2 v0.4.2 v10.20.30 v3 v0.1 v0.5.0-rc1 v0.5.0.1 V0.1.0 main "$sha40"; do
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
out="$(python3 -I "$ROOT/tools/adopt.py" guards "$work/not-there" 2>&1)"; rc=$?
record "guards: a missing directory is refused, not a traceback" "nonzero/yes/no" \
  "$(nonzero "$rc")/$(has "$out" 'not a directory')/$(has "$out" Traceback)"
mkdir -p "$work/dir-named-yml/ci.yml"
out="$(python3 -I "$ROOT/tools/adopt.py" guards "$work/dir-named-yml" 2>&1)"; rc=$?
record "guards: a directory named like a workflow is skipped, not a traceback" "0/no" \
  "$rc/$(has "$out" Traceback)"
out="$(HOMEFIELD_MODE_RELEASE=abc python3 -I "$ROOT/tools/adopt.py" guard-snippet --mode simple 2>&1)"; rc=$?
record "a malformed HOMEFIELD_MODE_RELEASE is refused, not a traceback" "nonzero/yes/no" \
  "$(nonzero "$rc")/$(has "$out" 'HOMEFIELD_MODE_RELEASE is not a vX.Y.Z release')/$(has "$out" Traceback)"

# ── adopt --setup ──────────────────────────────────────────────────────────
echo "setup"
# tools/adopt.py setup, byte-exact: the routed job gets the expression and a
# comment, its cache key gains runner.arch, the guard's jobs: block lists
# exactly it, and the job carrying the guard step stays hosted.
mkdir -p "$work/setup-in"
cat >"$work/setup-in/ci.yml" <<EOF
name: CI
on: [pull_request]
jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5
      - uses: actions/cache@v5
        with:
          path: ~/.npm
          key: ${os_key}-npm-${hash_key}
  guard:
    runs-on: ubuntu-24.04-arm
    steps:
      - uses: actions/checkout@v5
      - name: Routing guard
        uses: i2Dev-com/homefield/routing-guard@v0.5.2
        with:
          jobs: |
            ci.yml:old
EOF
got="$(python3 -I "$ROOT/tools/adopt.py" setup "$work/setup-in" "$work/setup-out" --expression "$expr" 2>&1)"
rc_setup=$?
want="$(printf 'ROUTED\tci.yml:lint\nFILE\tci.yml\n')"
cat >"$work/setup-want.yml" <<EOF
name: CI
on: [pull_request]
jobs:
  lint:
    # Routed to the local HomeField runner (docs/adopting.md)
    runs-on: $expr
    steps:
      - uses: actions/checkout@v5
      - uses: actions/cache@v5
        with:
          path: ~/.npm
          key: ${os_key}-${arch_key}-npm-${hash_key}
  guard:
    runs-on: ubuntu-24.04-arm
    steps:
      - uses: actions/checkout@v5
      - name: Routing guard
        uses: i2Dev-com/homefield/routing-guard@v0.5.2
        with:
          jobs: |
            ci.yml:lint
EOF
record "setup: routes, comments, keys and the guard list, byte for byte" "0/yes/yes/1" \
  "$rc_setup/$(cmp -s "$work/setup-out/ci.yml" "$work/setup-want.yml" && echo yes)/$([ "$got" = "$want" ] && echo yes)/$(find "$work/setup-out" -type f | wc -l | tr -d ' ')"
# The no-op refusal, on its own fixture: every job that could route already
# carries the expression, and the guard already lists it. (Built by the suite
# like every fixture, not reused from a previous setup run: setup's own
# output, run through setup again, was flaky here in a way the tool's own
# 20-run determinism check on this same shape never reproduced.)
mkdir -p "$work/setup-done"
{ header; emit_job lint "$expr"; emit_job guard ubuntu-24.04-arm "$(guard ci.yml:lint)"; } >"$work/setup-done/ci.yml"
got="$(python3 -I "$ROOT/tools/adopt.py" setup "$work/setup-done" "$work/setup-out13" --expression "$expr" 2>&1)"
rc_setup=$?
record "setup: every job routed and listed already: the no-op refusal" "nonzero/yes/no" \
  "$(nonzero "$rc_setup")/$(has "$got" 'every job that could route already carries the expression, and the guard already lists it')/$([ -d "$work/setup-out13" ] && echo yes || echo no)"
got="$(python3 -I "$ROOT/tools/adopt.py" setup "$work/wf-norouted" "$work/setup-out2" --expression "$expr" 2>&1)"
rc_setup=$?
record "setup: a hosted job only inside the guard job: nothing to route, nothing staged" "nonzero/yes/no" \
  "$(nonzero "$rc_setup")/$(has "$got" 'nothing to route')/$([ -d "$work/setup-out2" ] && echo yes || echo no)"
got="$(python3 -I "$ROOT/tools/adopt.py" setup "$work/wf-label" "$work/setup-out3" --expression "$expr" 2>&1)"
rc_setup=$?
record "setup: a guard on another label stops the run, naming the flag to pass" "nonzero/yes" \
  "$(nonzero "$rc_setup")/$(has "$got" 'pass --label acme-ci')"
mkdir -p "$work/setup-x64"
{ header; emit_job lint "$expr_x64" "$(guard_opts ci.yml:lint 'arch: x64')"; } >"$work/setup-x64/ci.yml"
got="$(python3 -I "$ROOT/tools/adopt.py" setup "$work/setup-x64" "$work/setup-out4" --expression "$expr" 2>&1)"
rc_setup=$?
record "setup: a guard routed on x64 is refused, the VM is arm64" "nonzero/yes/no" \
  "$(nonzero "$rc_setup")/$(has "$got" 'arch x64')/$([ -d "$work/setup-out4" ] && echo yes || echo no)"

# A locally-routed nightly (schedule-only, already on the expression) must
# stay in the guard's list — routing_guard's list is exact across all files —
# even though setup adds no run-on change to it.
mkdir -p "$work/setup-nightly"
{ header; emit_job lint ubuntu-latest "$(guard ci.yml:lint)"; } >"$work/setup-nightly/ci.yml"
{ printf 'name: Nightly\non:\n  schedule:\n    - cron: "0 5 * * *"\njobs:\n'; emit_job e2e "$expr" "$(cache_step "${os_key}-pw-${hash_key}")"; } >"$work/setup-nightly/nightly.yml"
got="$(python3 -I "$ROOT/tools/adopt.py" setup "$work/setup-nightly" "$work/setup-out5" --expression "$expr" 2>&1)"
rc_setup=$?
record "setup: an opted-in job on a schedule-only workflow stays listed" "0/yes/1/no" \
  "$rc_setup/$(has "$got" 'ROUTED	nightly.yml:e2e')/$(grep -c 'nightly.yml:e2e' "$work/setup-out5/ci.yml")/$([ -f "$work/setup-out5/homefield-routing.yml" ] && echo yes || echo no)"
record "...and the schedule-only file's cache key gains runner.arch too" "yes/1" \
  "$(has "$got" 'FILE	nightly.yml')/$(grep -cF "$arch_key" "$work/setup-out5/nightly.yml")"
# --jobs is an addition on top of what is already routed, not a replacement:
# lint and test carry the expression and stay listed although --jobs omits
# them; stderr (the spaced-file note) is kept out of the exact compare.
got="$(python3 -I "$ROOT/tools/adopt.py" setup "$work/wf-ready" "$work/setup-out6" --expression "$expr" --jobs ci.yml:build 2>"$work/err6")"
rc_setup=$?
want="$(printf 'ROUTED\tci.yml:build\nROUTED\tci.yml:lint\nROUTED\tci.yml:test\nFILE\tci.yml')"
record "setup --jobs: already-routed lint and test stay listed, only build is added" \
  "0/$want" \
  "$rc_setup/$got"
mkdir -p "$work/setup-source"
{ header; emit_job lint ubuntu-latest "$(printf '      - name: Routing guard\n        uses: i2Dev-com/homefield/routing-guard@v0.3.0\n        with:\n          jobs: |\n            ci.yml:lint')"; } >"$work/setup-source/ci.yml"
got="$(python3 -I "$ROOT/tools/adopt.py" setup "$work/setup-source" "$work/setup-out7" --expression "$expr" 2>&1)"
rc_setup=$?
record "setup: a guard pinned to another release stops the run before staging" "nonzero/yes/no" \
  "$(nonzero "$rc_setup")/$(has "$got" 'cannot recognize')/$([ -d "$work/setup-out7" ] && echo yes || echo no)"
mkdir -p "$work/setup-inline"
{ header; emit_job j ubuntu-latest "$(printf '      - name: Routing guard\n        uses: i2Dev-com/homefield/routing-guard@v0.5.2\n        with:\n          jobs: ci.yml:j')"; emit_job k ubuntu-latest; } >"$work/setup-inline/ci.yml"
got="$(python3 -I "$ROOT/tools/adopt.py" setup "$work/setup-inline" "$work/setup-out8" --expression "$expr" 2>&1)"
rc_setup=$?
record "setup: an inline jobs: value becomes the block form listing the routed job" "0/yes/1/0" \
  "$rc_setup/$(has "$got" 'ROUTED	ci.yml:k')/$(grep -c 'jobs: |' "$work/setup-out8/ci.yml")/$(grep -cF 'jobs: ci.yml:j' "$work/setup-out8/ci.yml")"
got="$(python3 -I "$ROOT/tools/adopt.py" setup "$work/wf-twoguards" "$work/setup-out9" --expression "$expr_acme" 2>&1)"
rc_setup=$?
record "setup: two passing guards refuse the run rather than pick one" "nonzero/yes/no" \
  "$(nonzero "$rc_setup")/$(has "$got" 'more than one routing-guard step')/$([ -d "$work/setup-out9" ] && echo yes || echo no)"
got="$(python3 -I "$ROOT/tools/adopt.py" setup "$work/wf-ready" "$work/setup-out11" --expression "$expr" --jobs ci.yml:missing 2>&1)"
rc_setup=$?
record "setup --jobs naming a job that cannot route: refused, naming it" "nonzero/yes/no" \
  "$(nonzero "$rc_setup")/$(has "$got" 'nothing to route: ci.yml:missing cannot be routed')/$([ -d "$work/setup-out11" ] && echo yes || echo no)"
mkdir -p "$work/setup-seq"
# The guard's own job keeps its runner, so a job to route has to exist beside
# it: `j` runs the guard, whose jobs: list is in sequence form, and `k` routes.
{ header; emit_job j ubuntu-latest "$(printf '      - name: Routing guard\n        uses: i2Dev-com/homefield/routing-guard@v0.5.2\n        with:\n          jobs:\n            - ci.yml:k')"; emit_job k ubuntu-latest; } >"$work/setup-seq/ci.yml"
got="$(python3 -I "$ROOT/tools/adopt.py" setup "$work/setup-seq" "$work/setup-out12" --expression "$expr" 2>&1)"
rc_setup=$?
record "setup: a jobs: list in sequence form is refused, not rewritten" "nonzero/yes/no" \
  "$(nonzero "$rc_setup")/$(has "$got" 'does not have a jobs: list setup can rewrite')/$([ -d "$work/setup-out12" ] && echo yes || echo no)"
# An edited file is written with LF endings even when the original had CRLF.
mkdir -p "$work/setup-crlf"
{ header; emit_job lint ubuntu-latest; } | sed 's/$/\r/' >"$work/setup-crlf/ci.yml"
got="$(python3 -I "$ROOT/tools/adopt.py" setup "$work/setup-crlf" "$work/setup-out10" --expression "$expr" 2>&1)"
rc_setup=$?
record "setup: a CRLF workflow is staged with LF endings" "0/yes/0" \
  "$rc_setup/$(has "$got" 'ROUTED	ci.yml:lint')/$(grep -c $'\r' "$work/setup-out10/ci.yml")"

# The shell path over the fake gh. wf-ready routes lint and test already;
# --setup adds the hosted build job. "my flow.yaml" is not routed: a space
# in the file name is one the guard's jobs: list cannot hold.
adopt -- --setup --dry-run
record "--setup --dry-run: plans the jobs, sends nothing" "0/yes/yes/yes/0/0" \
  "$rc/$(has "$out" 'setup: routes ci.yml:build ci.yml:lint ci.yml:test')/$(has "$out" 'my flow.yaml: its jobs are not routed')/$(has "$out" 'dry run: nothing was sent')/$(called 'X POST')/$(called 'X PUT')"
adopt -- --setup
record "--setup: branch, one write per file, pull request" "0/1/1/1/yes" \
  "$rc/$(called 'X POST repos/acme/app/git/refs')/$(called 'X PUT repos/acme/app/contents/.github/workflows/ci.yml')/$(called 'X POST repos/acme/app/pulls')/$(has "$out" 'https://github.com/acme/app/pull/77')"
record "...the sha lookup is a GET with the branch ref, not the POST -f alone would send" "1" \
  "$(called '-X GET repos/acme/app/contents/.github/workflows/ci.yml -f ref=homefield/route-to-local')"
record "...the spaced file is not written, and the body lists the jobs and step 5" "0/yes/yes" \
  "$(called 'X PUT repos/acme/app/contents/.github/workflows/my%20flow.yaml')/$(has "$(cat "$work/pr_body")" 'ci.yml:build')/$(has "$(cat "$work/pr_body")" 'step 5')"
record "...and the branch stands on the fake remote" "yes" \
  "$([ -f "$work/branch-homefield_route-to-local" ] && echo yes || echo no)"
adopt -- --setup
record "--setup twice: the existing branch is refused, no second pull request" "nonzero/yes/0" \
  "$(nonzero "$rc")/$(has "$out" 'already exists')/$(called 'X POST repos/acme/app/pulls')"
rm -f "$work/branch-homefield_route-to-local"
adopt GH_PUT_FAIL=1 -- --setup
record "--setup failing mid-write: the branch is taken back, nothing is left" "nonzero/yes/1/gone" \
  "$(nonzero "$rc")/$(has "$out" 'could not write')/$(called 'X DELETE repos/acme/app/git/refs/heads/homefield/route-to-local')/$([ -f "$work/branch-homefield_route-to-local" ] && echo present || echo gone)"

# The workflow scope (#165): GitHub requires a classic PAT's workflow scope to
# write .github/workflows/ and answers a bare 404 without it, though the same
# token writes everywhere else. Only a reported scope list proves the answer;
# one that is not reported must go on and be told by the write itself.
adopt GH_AUTH='user|repo, gist' -- --setup
record "--setup, scope proven absent: stopped before the branch, with the fix" "nonzero/yes/0/1" \
  "$(nonzero "$rc")/$(has "$out" 'no workflow scope')/$(called 'X POST')/$(called 'auth status')"
adopt GH_AUTH='user|repo, workflow, admin:org' -- --setup
record "--setup, scope present: goes on to branch and pull request" "0/1/yes" \
  "$rc/$(called 'X POST repos/acme/app/git/refs')/$(has "$out" 'created pull request')"
rm -f "$work/branch-homefield_route-to-local"
adopt GH_AUTH='user|admin:org, repo, workflow' -- --setup
record "--setup, scopes in another order: the match still hits" "0/1" \
  "$rc/$(called 'X POST repos/acme/app/git/refs')"
rm -f "$work/branch-homefield_route-to-local"
adopt GH_AUTH='user|' -- --setup
record "--setup, no scopes reported (an App token): cannot tell, goes on" "0/1/no" \
  "$rc/$(called 'X POST repos/acme/app/git/refs')/$(has "$out" 'workflow scope')"
rm -f "$work/branch-homefield_route-to-local"
adopt GH_AUTH_FAIL=1 -- --setup
record "--setup, gh cannot be asked: cannot tell, goes on" "0/1" \
  "$rc/$(called 'X POST repos/acme/app/git/refs')"
rm -f "$work/branch-homefield_route-to-local"
adopt GITHUB_TOKEN=stubtoken GH_PUT_404=1 -- --setup
record "--setup, an env token whose write 404s: the failure names the scope, the branch goes back" "nonzero/yes/yes/gone/0" \
  "$(nonzero "$rc")/$(has "$out" 'lacks the workflow scope')/$(has "$out" 'gh auth refresh')/$([ -f "$work/branch-homefield_route-to-local" ] && echo present || echo gone)/$(called 'auth status')"
adopt GH_WF="$work/wf-noguard" -- --setup
record "--setup without a guard: the pull request adds homefield-routing.yml" "0/yes/1/1" \
  "$rc/$(has "$out" 'setup: changes .github/workflows/homefield-routing.yml')/$(called 'X PUT repos/acme/app/contents/.github/workflows/homefield-routing.yml')/$(called 'X POST repos/acme/app/pulls')"
record "...and no group write, no switch: those are step 5" "0/0" \
  "$(called 'runner-groups/42/repositories')/$(called 'variable set')"
record "...and a new file's payload carries no sha (the Contents create form)" "no" \
  "$(grep -q '"sha"' "$work/put-homefield-routing.yml.json" && echo yes || echo no)"
rm -f "$work/branch-homefield_route-to-local"

# Simple mode end to end. Without a guard, --setup routes with the one-clause
# expression and writes the guard step in simple mode; --guards switches the
# pull request to the guarded expression. The PUT payloads are the files the
# fake remote received, their content base64 in the Contents form.
mkdir -p "$work/wf-simple"
{ header; emit_job lint ubuntu-latest; } >"$work/wf-simple/ci.yml"
payload() { python3 -c 'import json,base64,sys;print(base64.b64decode(json.load(open(sys.argv[1]))["content"]).decode())' "$work/put-$1.json"; }
adopt GH_WF="$work/wf-simple" -- --setup
record "--setup, no guard: simple mode, routing workflow and ci.yml written" "0/yes/yes/2" \
  "$rc/$(has "$out" 'setup: changes .github/workflows/homefield-routing.yml')/$(has "$out" 'setup: changes .github/workflows/ci.yml')/$(called 'X PUT')"
record "...the guard step carries mode: simple, and no events or dependabot" "yes/no/no" \
  "$(payload homefield-routing.yml | grep -q '          mode: simple' && echo yes || echo no)/$(payload homefield-routing.yml | grep -q '          events:' && echo yes || echo no)/$(payload homefield-routing.yml | grep -q '          dependabot:' && echo yes || echo no)"
record "...the routed job carries the simple expression, with the comment" "yes/yes/no" \
  "$(payload ci.yml | grep -qF "runs-on: $expr_simple" && echo yes || echo no)/$(payload ci.yml | grep -q 'Routed to the local HomeField runner' && echo yes || echo no)/$(payload ci.yml | grep -q 'github.event_name' && echo yes || echo no)"
rm -f "$work/branch-homefield_route-to-local"
adopt GH_WF="$work/wf-simple" -- --guards --setup
record "--setup --guards, no guard: the guarded expression, and no mode input" "yes/no" \
  "$(payload ci.yml | grep -qF "runs-on: $expr" && echo yes || echo no)/$(payload homefield-routing.yml | grep -q '          mode:' && echo yes || echo no)"
rm -f "$work/branch-homefield_route-to-local"
# Before the release that carries --mode is cut, a checkout whose RELEASE
# predates it refuses to write simple mode: the guard step it writes pins
# the release, whose checker would fail the workflows on their first pull
# request. A threshold above this checkout's RELEASE reproduces that here.
run_fn HOMEFIELD_MODE_RELEASE=v0.5.3 GH_GROUPS="$work/groups-selected" GH_MEMBERS="$work/members-other" GH_WF="$work/wf-simple" -- cmd_adopt --repo acme/app --setup
record "--setup simple before the mode release exists: refused, --guards named" "nonzero/yes/0" \
  "$(nonzero "$rc")/$(has "$out" 'is not cut yet; pass --guards')/$(called 'X POST')"

# A repository already on the guarded expression but with no guard yet: simple
# mode lists the jobs as they are (grandfathered), and rewrites nothing.
mkdir -p "$work/wf-canonical"
{ header; emit_job lint "$expr"; } >"$work/wf-canonical/ci.yml"
adopt GH_WF="$work/wf-canonical" -- --setup
record "--setup, no guard, jobs already guarded: listed, ci.yml not rewritten" "0/yes/1/no" \
  "$rc/$(has "$out" 'setup: routes ci.yml:lint')/$(called 'X PUT')/$(has "$out" 'setup: changes .github/workflows/ci.yml')"
rm -f "$work/branch-homefield_route-to-local"

# A guard step already in simple mode: --setup keeps it and routes with the
# simple expression; --guards is refused, and plain adopt follows the guard.
mkdir -p "$work/wf-simpleguard"
{ header; emit_job lint "$expr_simple"; emit_job build ubuntu-latest; \
  emit_job guardjob ubuntu-latest "$(guard_opts ci.yml:lint 'mode: simple')"; } >"$work/wf-simpleguard/ci.yml"
adopt GH_WF="$work/wf-simpleguard" -- --setup
record "--setup on a simple-mode guard: kept, the hosted job routed with the simple expression" "0/yes/1/yes/yes" \
  "$rc/$(has "$out" 'setup: routes ci.yml:build')/$(called 'X PUT repos/acme/app/contents/.github/workflows/ci.yml')/$(payload ci.yml | grep -q '          mode: simple' && echo yes || echo no)/$(payload ci.yml | grep -qF "runs-on: $expr_simple" && echo yes || echo no)"
rm -f "$work/branch-homefield_route-to-local"
adopt GH_WF="$work/wf-simpleguard" -- --guards --setup
record "--setup --guards on a simple-mode guard: refused" "nonzero/yes" \
  "$(nonzero "$rc")/$(has "$out" 'uses mode simple, but this run asks for guards')"
adopt GH_WF="$work/wf-simpleguard" --
record "plain adopt on a simple-mode guard: ready, CI_RUNNER switched" "0/yes/yes/no/1" \
  "$rc/$(has "$out" 'routing: ready')/$(has "$out" 'these jobs are routed: ci.yml:lint')/$(has "$out" 'ci.yml:build')/$(called 'variable set CI_RUNNER --repo acme/app --body local')"

# A repository mixing the shapes, with a simple-mode guard listing both: plain
# adopt follows the guard's mode and accepts both.
mkdir -p "$work/wf-mixed"
{ header; emit_job lint "$expr_simple"; emit_job test "$expr"; \
  emit_job guardjob ubuntu-latest "$(guard_opts ci.yml:lint 'jobs: |' '            ci.yml:lint' '            ci.yml:test' 'mode: simple')"; } >"$work/wf-mixed/ci.yml"
adopt GH_WF="$work/wf-mixed" --
record "plain adopt, a simple job and a guarded one: both routed, ready" "0/yes/yes/1" \
  "$rc/$(has "$out" 'routing: ready')/$(has "$out" 'these jobs are routed: ci.yml:lint ci.yml:test')/$(called 'variable set CI_RUNNER --repo acme/app --body local')"
adopt GH_WF="$work/wf-mixed" -- --guards
record "...the same repository with --guards: refused, the guard is simple" "nonzero/yes/0" \
  "$(nonzero "$rc")/$(has "$out" 'uses mode simple, but --guards is given')/$(called 'variable set')"
adopt GH_REPO="$(printf 'false\t555\tmain\tOrganization')" -- --setup
record "--setup on a public repository: refused, as ever" "nonzero/yes/0" \
  "$(nonzero "$rc")/$(has "$out" 'is public')/$(called 'X POST')"
rm -f "$work/branch-homefield_route-to-local"
adopt GH_EXISTING_SHA=e1e1e1e1 -- --setup
record "--setup on existing files: the update PUT sends the sha the GET read" "0/1/yes" \
  "$rc/$(called '-X GET repos/acme/app/contents/.github/workflows/ci.yml -f ref=homefield/route-to-local')/$(grep -q '"sha": "e1e1e1e1"' "$work/put-ci.yml.json" && echo yes || echo no)"

# ── adopt --setup --wait ───────────────────────────────────────────────────
echo "wait"
pr_url="https://github.com/acme/app/pull/77"
# wait_adopt "<word>..." <env...> -- <adopt args>: an adopt run whose pull
# request answers with the words in turn (see the stub), polled with no
# interval. A later ADOPT_WAIT_INTERVAL in the env wins.
wait_adopt() {
  local seq="$1" words
  shift
  read -ra words <<<"$seq"
  printf '%s\n' "${words[@]}" >"$work/pr-seq"
  rm -f "$work/pr_polls" "$work/pr_merged" "$work/branch-homefield_route-to-local"
  adopt ADOPT_WAIT_INTERVAL=0 GH_PR_SEQ="$work/pr-seq" "$@"
}
polls() { called 'api repos/acme/app/pulls/77 '; }
group_put="X PUT $put_path"
# line_of <first|last> <pattern>: where in the recorded calls it is (empty: never).
line_of() { grep -n -e "$2" "$calls" | cut -d: -f1 | if [ "$1" = first ]; then head -n 1; else tail -n 1; fi; }
untouched() { echo "$(called "$group_put")/$(called 'variable set')/$(called 'X DELETE')"; }

run_fn -- cmd_adopt --repo acme/app --wait
record "--wait without --setup: refused, before any gh call" "nonzero/yes/0" \
  "$(nonzero "$rc")/$(has "$out" '--wait goes with --setup')/$(called gh)"
run_fn -- cmd_adopt --repo acme/app --wait-timeout 5
record "--wait-timeout without --wait: refused" "nonzero/yes/0" \
  "$(nonzero "$rc")/$(has "$out" '--wait-timeout only goes with --wait')/$(called gh)"
run_fn -- cmd_adopt --repo acme/app --setup --wait-timeout 5
record "--wait-timeout with --setup but without --wait: refused" "nonzero/yes" \
  "$(nonzero "$rc")/$(has "$out" '--wait-timeout only goes with --wait')"
for bad in 0 abc -5 1.5 007 1000000; do
  run_fn -- cmd_adopt --repo acme/app --setup --wait --wait-timeout "$bad"
  record "--wait-timeout $bad: refused, before any gh call" "nonzero/yes/0" \
    "$(nonzero "$rc")/$(has "$out" 'whole number of minutes')/$(called gh)"
done

# merged on the first read
wait_adopt "merged" -- --setup --wait
record "merged at the first read: group access and the switch follow, in this run" "0/1/1/1/yes" \
  "$rc/$(polls)/$(called "$group_put")/$(called 'variable set CI_RUNNER --repo acme/app --body local')/$(has "$out" 'done: acme/app: runner group added; routing ready; CI_RUNNER set to local')"
record "...the wait is announced with the pull request, Ctrl-C and the way to go on by hand" "yes/yes/yes" \
  "$(has "$out" "waiting for ${pr_url} to be merged (up to 60 min)")/$(has "$out" 'Ctrl-C is safe')/$(has "$out" 'carry on by hand once it is merged: homefield adopt --repo acme/app')"
record "...the pull request came first, then the group, then the switch" "yes/yes" \
  "$(before "$(cat "$calls")" 'X POST repos/acme/app/pulls' "$group_put")/$(before "$(cat "$calls")" "$group_put" 'variable set CI_RUNNER')"
record "...the repository and its workflows are read again after the merge" "2/2" \
  "$(called '^gh api repos/acme/app ')/$(called '^gh api -X GET repos/acme/app/contents/.github/workflows -f')"
record "...and the next-step line says it is waiting, without offering --wait" "yes/no" \
  "$(has "$out" 'next: review and merge it; this run waits for that')/$(has "$out" 'does both in one run')"
record "...a merged pull request leaves its branch alone" "0" "$(called 'X DELETE')"

# open, open, merged: nothing is added or switched before the merge answer
wait_adopt "open open merged" ADOPT_WAIT_INTERVAL=10 -- --setup --wait
record "open, open, merged: three reads, a sleep of the interval between each" "0/3/2" "$rc/$(polls)/$(called '^sleep 10$')"
last_poll="$(line_of last 'api repos/acme/app/pulls/77 ')"
record "...the group and the switch come only after the merged answer" "yes/yes" \
  "$([ "$(line_of first "$group_put")" -gt "$last_poll" ] && echo yes || echo no)/$([ "$(line_of first 'variable set')" -gt "$last_poll" ] && echo yes || echo no)"
record "...nothing was written to the group or the variable before it" "0" \
  "$(head -n "$last_poll" "$calls" | grep -c -e "$group_put" -e 'variable set')"

# closed without a merge
wait_adopt "open closed" -- --setup --wait
record "closed without a merge: stops, saying nothing was switched, exit 4" "4/yes/yes/2" \
  "$rc/$(has "$out" 'was closed without being merged')/$(has "$out" 'Nothing was switched and no group access was changed')/$(polls)"
record "...no group call, no variable, the branch is not deleted" "0/0/0" "$(untouched)"

# the timeout: 1 minute at a 30 s interval is two reads and one sleep between them
wait_adopt "open" ADOPT_WAIT_INTERVAL=30 -- --setup --wait --wait-timeout 1
record "still open at the timeout: stops, naming the command to run after the merge, exit 4" "4/yes/yes/2/1" \
  "$rc/$(has "$out" "${pr_url} is still open after 1 min")/$(has "$out" 'Once it is merged, run: homefield adopt --repo acme/app')/$(polls)/$(called '^sleep 30$')"
record "...no group call, no variable, the branch is not deleted" "0/0/0" "$(untouched)"
wait_adopt "open" ADOPT_WAIT_INTERVAL=30 -- --setup --wait --wait-timeout 3
record "--wait-timeout 3 at 30 s: six reads" "6" "$(polls)"
wait_adopt "open" -- --setup --wait --wait-timeout 1
record "no sleep at all with a zero interval" "0" "$(called '^sleep')"

# a progress line about once a minute, not at every read
wait_adopt "open open open open open merged" ADOPT_WAIT_INTERVAL=30 -- --setup --wait --wait-timeout 3
record "five open reads at 30 s: a progress line at each minute, not each read" "0/6/2" \
  "$rc/$(polls)/$(printf '%s\n' "$out" | grep -c 'still waiting for')"
record "...saying how long it has waited" "yes" "$(has "$out" "still waiting for ${pr_url} to be merged (1 of 3 min)")"

# a read that fails is not a closed pull request
wait_adopt "fail fail fail fail merged" -- --setup --wait
record "four failed reads in a row, then merged: carried on" "0/5/1" "$rc/$(polls)/$(called "$group_put")"
wait_adopt "fail fail open fail fail fail fail merged" -- --setup --wait
record "failures that an answer interrupts do not add up" "0/8/1" "$rc/$(polls)/$(called "$group_put")"
wait_adopt "fail" -- --setup --wait
record "five failed reads in a row: stops, not as closed, exit 4" "4/yes/no/no/5" \
  "$rc/$(has "$out" 'could not read the state of')/$(has "$out" 'was closed')/$(has "$out" 'still open')/$(polls)"
record "...with gh's reason, and the command to run after the merge" "yes/yes" \
  "$(has "$out" 'HTTP 502')/$(has "$out" 'Once it is merged, run: homefield adopt --repo acme/app')"
record "...no group call, no variable, the branch is not deleted" "0/0/0" "$(untouched)"
wait_adopt "garbage" -- --setup --wait
record "an answer that cannot be read counts as a failed read, exit 4" "4/yes/no/5" \
  "$rc/$(has "$out" 'could not read the state of')/$(has "$out" 'was closed')/$(polls)"

# the merge does not switch anything by itself: the guard still decides
wait_adopt "merged" GH_WF="$work/wf-noguard" GH_WF_MERGED="$work/wf-noguard" -- --setup --wait
record "merged, but the routing is still not ready: not switched, the group untouched, exit 5" "5/yes/yes/0/0" \
  "$rc/$(has "$out" 'not switched: merge the routing first')/$(has "$out" 'no routing-guard step in .github/workflows')/$(called "$group_put")/$(called 'variable set')"
wait_adopt "open merged" GH_WF="$work/wf-noguard" GH_WF_MERGED="$work/wf-ready" -- --setup --wait
record "the workflows are read at the merge, not before: the merged routing is what is checked" "0/1/1" \
  "$rc/$(called "$group_put")/$(called 'variable set CI_RUNNER --repo acme/app --body local')"
wait_adopt "merged" GH_CI_RUNNER=hosted -- --setup --wait --no-switch
record "--no-switch still holds after the wait" "0/1/0" "$rc/$(called "$group_put")/$(called 'variable set')"

# a dry run sends nothing, so there is no pull request to wait for
wait_adopt "merged" -- --setup --wait --dry-run
record "--setup --wait --dry-run: says so, sends nothing, reads no pull request" "0/yes/0/0/0/0" \
  "$rc/$(has "$out" '--wait has nothing to wait for')/$(polls)/$(called 'X POST')/$(called 'X PUT')/$(called 'variable set')"
# without --wait the line still offers it
wait_adopt "merged" -- --setup
record "--setup alone: no read of the pull request, and --wait is offered" "0/0/yes" \
  "$rc/$(polls)/$(has "$out" 'adopt --setup --wait does both in one run')"

# The command to run after the merge keeps this run's --label and --group (a
# plain adopt without --group looks at homefield-ci, and would add the
# repository to the wrong group). A group name with a space is quoted.
plain_hand='homefield adopt --repo acme/app --label homefield-ci --group my\ group'
wait_adopt "open" ADOPT_WAIT_INTERVAL=30 -- --setup --wait --wait-timeout 1 --label homefield-ci --group "my group"
record "the hand-off keeps --label and --group, quoted: the wait line, the timeout, and the pull request body" "yes/yes/yes" \
  "$(has "$out" "carry on by hand once it is merged: ${plain_hand}")/$(has "$out" "Once it is merged, run: ${plain_hand}")/$(has "$(cat "$work/pr_body")" "\`${plain_hand}\` adds the repository")"
wait_adopt "merged" -- --setup --group other-group
record "...the next-step line without --wait too, and --group alone adds no --label" "yes/no" \
  "$(has "$out" 'then homefield adopt --repo acme/app --group other-group (docs/adopting.md')/$(has "$out" '--label')"
wait_adopt "open" ADOPT_WAIT_INTERVAL=30 -- --setup --wait --wait-timeout 1
record "...no flags given, none added" "yes/no" "$(has "$out" 'Once it is merged, run: homefield adopt --repo acme/app')/$(has "$out" 'run: homefield adopt --repo acme/app --')"

# a pull request URL with no number to follow
wait_adopt "merged" GH_PR_URL=https://github.com/acme/app/pull/x -- --setup --wait
record "a pull request number that cannot be read: stops, the pull request and branch stay, exit 4" "4/yes/0/0" \
  "$rc/$(has "$out" 'could not read the pull request number')/$(polls)/$(called 'X DELETE')"

# The exit status of --wait (#156): 4 once the pull request exists and it is
# not merged, 5 once merged; before that, and without --wait, 1 as ever.
printf 'merged\n' >"$work/pr-seq"
: >"$work/branch-homefield_route-to-local"
adopt GH_PR_SEQ="$work/pr-seq" -- --setup --wait
record "--setup --wait, the branch is already there (no pull request): exit 1, no read of a pull request" "1/yes/0" \
  "$rc/$(has "$out" 'already exists')/$(polls)"
rm -f "$work/branch-homefield_route-to-local"
adopt GH_PR_SEQ="$work/pr-seq" GH_REPO="$(printf 'false\t555\tmain\tOrganization')" -- --setup --wait
record "--setup --wait on a public repository (no pull request): exit 1" "1/yes" "$rc/$(has "$out" 'is public')"
adopt GH_PR_SEQ="$work/pr-seq" GH_PUT_FAIL=1 -- --setup --wait
record "--setup --wait failing mid-write (no pull request): exit 1, the branch taken back" "1/yes/gone" \
  "$rc/$(has "$out" 'could not write')/$([ -f "$work/branch-homefield_route-to-local" ] && echo present || echo gone)"
adopt GH_PR_SEQ="$work/pr-seq" GH_WF="$work/wf-norouted" -- --setup --wait
record "--setup --wait with nothing to route (no pull request): exit 1" "1/yes" "$rc/$(has "$out" 'nothing to route')"
: >"$work/branch-homefield_route-to-local"
adopt -- --setup
record "--setup without --wait, the branch is already there: exit 1, as before" "1/yes" "$rc/$(has "$out" 'already exists')"
rm -f "$work/branch-homefield_route-to-local"
adopt GH_WF="$work/wf-noguard" --
record "plain adopt, routing not ready: exit 1, not the --wait statuses" "1/yes" "$rc/$(has "$out" 'not switched')"
# adopt_setup_exit, state by state (wait, pull request made, merged, status in)
exit_status() {
  run_fn -- eval "ADOPT_TMP=\$(mktemp -d); ADOPT_WAIT=$1 ADOPT_SETUP_PR_MADE=$2 ADOPT_WAIT_MERGED=$3; (trap adopt_setup_exit EXIT; exit $4)"
}
exit_status 1 1 0 1
record "exit trap: --wait, pull request open, status 1: 4" "4" "$rc"
exit_status 1 1 1 1
record "exit trap: --wait, pull request merged, status 1: 5" "5" "$rc"
exit_status 1 1 0 2
record "exit trap: ...any status but 0, 130 and 143 counts" "4" "$rc"
exit_status 1 1 0 130
record "exit trap: Ctrl-C keeps 130" "130" "$rc"
exit_status 1 1 1 143
record "exit trap: SIGTERM keeps 143, merged or not" "143" "$rc"
exit_status 1 1 1 0
record "exit trap: success stays 0" "0" "$rc"
exit_status 1 0 0 1
record "exit trap: --wait but no pull request yet: 1" "1" "$rc"
exit_status 0 1 0 1
record "exit trap: a pull request but no --wait: 1" "1" "$rc"

# Ctrl-C and SIGTERM in every phase of a --setup run (#158). The signals are
# real, sent to real processes: INT to the whole process group, as a terminal
# does, and TERM to the one process, as kill does. A phase is held still where
# a test can aim at it, by a gh that hangs (the stub records HUNG before it
# does) or by a real sleep, and the test waits for that record, not for a
# time. The note has to be true for the phase, and the status exactly 130 or
# 143: a signal that lands in a `|| die` must not turn into a failure status.
nap() { "$real_sleep" 0.05; }
# group_left <pgid>: how many processes of that group are alive.
group_left() { ps -A -o pgid= | awk -v g="$1" '$1 == g' | wc -l | tr -d ' '; }
# marker_wait <pattern>: until the stub has recorded it (10 s at most).
marker_wait() {
  local i=0
  while ! grep -q -e "$1" "$calls" && [ "$i" -lt 200 ]; do nap; i=$((i + 1)); done
}
# interrupt <INT|TERM|INT+TERM> <phase> [adopt|setup|setup-alone|parent]:
#   phase  pre (a write to the new branch is in flight), pending (the call that
#          opens the pull request), wait (the wait for the merge), merged (the
#          group access is in flight), switching (the CI_RUNNER write is), verify
#          (the pause between two reads of the re-run), double (as pre, and the
#          signal comes a second time while the cleanup runs, which finishes),
#          doublehang (the same, with a cleanup that hangs), branch (the call
#          that creates the branch)
#   mode   adopt on its own; setup's routing step around it (setup), signalled
#          in its whole process group; setup signalled alone, by its pid
#          (setup-alone); or adopt told that a parent process it was not started
#          by is setup (parent), which then ends without a signal reaching adopt
# It leaves rc, out, intr_tmp (temporary directories before/after) and intr_left
# (processes of the job's group still alive once it is over).
interrupt() { interrupt_run "$@" 2>/dev/null; } # (bash 3.2 reports a job killed by TERM)
interrupt_run() {
  local sigs="$1" phase="$2" mode="${3:-adopt}" pid i sig target tmp_before tmp_after status left first=1
  local seq=merged hang="" hang2="" secs2=2 wait_interval=30 verify_interval=600 drain=1 secs=30 fake="" marker cmd
  local args=(--setup --wait) extra=()
  case "$phase" in
    pre) seq=open hang="X PUT repos/acme/app/contents" ;;
    double) seq=open hang="X PUT repos/acme/app/contents" hang2="X DELETE" ;;
    doublehang) seq=open hang="X PUT repos/acme/app/contents" hang2="X DELETE" secs2=30 ;;
    branch) seq=open hang="X POST repos/acme/app/git/refs" ;;
    pending) seq=open hang="X POST repos/acme/app/pulls" ;;
    wait) seq=open ;;
    merged) hang="X PUT orgs/acme/actions/runner-groups" ;;
    switching) hang="variable set" ;;
    verify)
      args+=(--verify)
      extra=(GH_RUN="$work/run-going" GH_JOBS="$work/jobs-hostonly" GH_RUNLIST="$work/runlist-done" ADOPT_VERIFY_TRIES=100)
      ;;
  esac
  case "$mode" in
    setup-alone) wait_interval=2 drain=15 ;;
    parent) verify_interval=2 drain=15 ;;
  esac
  extra+=(ADOPT_VERIFY_INTERVAL="$verify_interval")
  case "$phase" in
    wait) marker="^sleep ${wait_interval}\$" ;;
    verify) marker="^sleep ${verify_interval}\$" ;;
    *) marker='^HUNG$' ;;
  esac
  # a TERM to one process only is acted on when the foreground gh is over: let
  # it finish, as it would, instead of waiting out its hang
  case "${sigs%%+*}" in INT) ;; *) [ "$mode" = setup ] || secs=2 ;; esac
  cmd=(cmd_adopt --repo acme/app "${args[@]}")
  case "$mode" in setup | setup-alone) cmd=(setup_route_repo acme/app) ;; esac
  printf '%s\n' "$seq" >"$work/pr-seq"
  rm -f "$work/pr_polls" "$work/pr_merged" "$work/branch-homefield_route-to-local" "$work/hung" "$work/hung2" "$work/jobs-n"
  : >"$calls"
  tmp_before="$(find "$work/tmp" -mindepth 1 | wc -l)"
  if [ "$mode" = parent ]; then
    "$real_sleep" 1000 &
    fake=$!
  fi
  # job control gives the background job its own process group and leaves
  # SIGINT unignored, as a Ctrl-C at a terminal finds it
  set -m
  # shellcheck disable=SC2016  # the -c script is expanded by the inner bash
  env -i HOME="$work" PATH="$stubs" TMPDIR="$work/tmp" CALLS="$calls" HOMEFIELD_SOURCE_ONLY=1 \
    GH_GROUPS="$work/groups-selected" GH_MEMBERS="$work/members-other" GH_WF="$work/wf-ready" \
    GH_PR_SEQ="$work/pr-seq" ADOPT_WAIT_INTERVAL="$wait_interval" SLEEP_REAL=1 \
    GH_HANG="$hang" GH_HANG_SECS="$secs" GH_HANG2="$hang2" GH_HANG2_SECS="$secs2" GH_HANG_SLEEP="$real_sleep" \
    FAKE_PARENT="$fake" "${extra[@]}" \
    "$BASH" -c '. "$1"; shift; if [ -n "$FAKE_PARENT" ]; then ADOPT_PARENT_PID=$FAKE_PARENT; fi; "$@"' _ "$ROOT/bin/homefield" "${cmd[@]}" \
    >"$work/int.out" 2>&1 </dev/null &
  pid=$!
  set +m
  marker_wait "$marker"
  for sig in ${sigs//+/ }; do
    # a second signal comes while the first one's cleanup is still running
    if [ "$first" = 0 ]; then marker_wait '^HUNG2$'; fi
    first=0
    target="$pid"
    if [ "$sig" = INT ] || [ "$mode" = setup ]; then target="-$pid"; fi
    if [ "$mode" = parent ]; then
      kill "$fake"
      wait "$fake" 2>/dev/null
    else
      kill "-$sig" -- "$target"
    fi
  done
  i=0
  while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 200 ]; do nap; i=$((i + 1)); done
  if kill -0 "$pid" 2>/dev/null; then
    kill -9 -- "-$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    status=hung
  else
    wait "$pid"
    status=$?
  fi
  # what is left of the group (the job's process group is its pid): checked
  # once the job is over, for as long as the mode needs (setup ended alone
  # leaves its adopt to notice, within one poll interval)
  i=0
  left="$(group_left "$pid")"
  while [ "$left" != 0 ] && [ "$i" -lt $((drain * 20)) ]; do
    nap
    i=$((i + 1))
    left="$(group_left "$pid")"
  done
  intr_left="$left"
  [ "$left" = 0 ] || kill -9 -- "-$pid" 2>/dev/null
  [ -z "$fake" ] || kill "$fake" 2>/dev/null
  tmp_after="$(find "$work/tmp" -mindepth 1 | wc -l)"
  rc="$status"
  out="$(cat "$work/int.out")"
  intr_tmp="$tmp_before/$tmp_after"
}
branch_there() { [ -f "$work/branch-homefield_route-to-local" ] && echo yes || echo no; }
tmp_gone() { [ "${intr_tmp%/*}" = "${intr_tmp#*/}" ] && echo yes || echo "no ($intr_tmp)"; }
notes_n() { printf '%s\n' "$out" | grep -c -F -e "$1" || true; }
pr_note='interrupted before the pull request was opened. Nothing was switched or added to the runner group.'
merged_note="interrupted after ${pr_url} was merged, before adopt finished"
plain_cmd='homefield adopt --repo acme/app'
branch_delete='X DELETE repos/acme/app/git/refs/heads/homefield/route-to-local'

# while waiting for the merge: the pull request and its branch stay
interrupt INT wait
record "Ctrl-C while waiting: exit 130, not left sleeping, no process of the job left" "130/0" "$rc/$intr_left"
record "...it says the pull request and branch are untouched, and the command to go on with" "yes/yes/yes" \
  "$(has "$out" "interrupted while waiting for ${pr_url}")/$(has "$out" 'untouched')/$(has "$out" "run: ${plain_cmd}")"
record "...no group call, no variable, no branch delete, nothing said about removing it" "0/0/0/no" \
  "$(called "$group_put")/$(called 'variable set')/$(called 'X DELETE')/$(has "$out" 'removing homefield/route-to-local')"
record "...the branch is still there, and the temporary directory is gone" "yes/yes" "$(branch_there)/$(tmp_gone)"
interrupt TERM wait
record "SIGTERM while waiting: exit 143, guidance, branch kept, temporary directory gone, nothing left running" "143/yes/0/yes/yes/0" \
  "$rc/$(has "$out" "run: ${plain_cmd}")/$(called 'X DELETE')/$(branch_there)/$(tmp_gone)/$intr_left"

# before the pull request: the branch it made has no pull request, so it is taken back
interrupt INT pre
record "Ctrl-C before the pull request exists, a write to the branch in flight: exactly 130, nothing left running" "130/0" "$rc/$intr_left"
record "...the note says so, and that nothing was switched or added to the group" "1/no" \
  "$(notes_n "$pr_note")/$(has "$out" 'untouched')"
record "...the branch it made is taken back, after the note, and the temporary directory is gone" "1/gone/yes/yes" \
  "$(called "$branch_delete")/$([ "$(branch_there)" = yes ] && echo there || echo gone)/$(before "$out" 'interrupted before' 'removing homefield/route-to-local')/$(tmp_gone)"
record "...no group call, no variable, no pull request" "0/0/0" "$(called "$group_put")/$(called 'variable set')/$(called 'X POST repos/acme/app/pulls')"
interrupt TERM pre
record "SIGTERM before the pull request exists: exactly 143, the same note, the branch taken back" "143/1/1/gone/0" \
  "$rc/$(notes_n "$pr_note")/$(called "$branch_delete")/$([ "$(branch_there)" = yes ] && echo there || echo gone)/$intr_left"

# while the pull request is being opened: it may exist, so its branch must stay
interrupt INT pending
record "Ctrl-C while the pull request is being opened: exactly 130, nothing left running" "130/0" "$rc/$intr_left"
record "...the note says it may exist, where to look, and that the branch was left" "yes/yes/yes/yes/no" \
  "$(has "$out" 'interrupted while the pull request was being opened; it may exist: look at https://github.com/acme/app/pulls')/$(has "$out" 'If there is none, delete the branch (gh api -X DELETE repos/acme/app/git/refs/heads/homefield/route-to-local) and run again. The branch was left in place')/$(has "$out" 'Nothing was switched or added to the runner group')/$(has "$out" 'interrupted')/$(has "$out" 'untouched')"
record "...the branch is not deleted (that would close a pull request that was just opened)" "0/yes/no" \
  "$(called 'X DELETE')/$(branch_there)/$(has "$out" 'removing homefield/route-to-local')"
interrupt TERM pending
record "SIGTERM while the pull request is being opened (gh finishes it): exactly 143, the branch kept, no delete" "143/0/yes/0" \
  "$rc/$(called 'X DELETE')/$(branch_there)/$intr_left"
record "...the note names the pull request, which exists" "yes" "$(has "$out" 'pull request')"

# after the merge, before the switch is over: what may or may not have happened
interrupt INT merged
record "Ctrl-C after the merge, the group access in flight: exactly 130, nothing left running" "130/0" "$rc/$intr_left"
record "...the note says the pull request was merged and adopt did not finish, and to run again" "1/yes/yes/yes" \
  "$(notes_n "$merged_note")/$(has "$out" 'may or may not have been added to the runner group')/$(has "$out" 'CI_RUNNER may or may not be set')/$(has "$out" "Run again to finish (it is safe to repeat): ${plain_cmd}")"
record "...nothing is claimed untouched, the branch is not deleted, no variable was set, the directory is gone" "no/0/0/yes" \
  "$(has "$out" 'untouched')/$(called 'X DELETE')/$(called 'variable set')/$(tmp_gone)"
interrupt TERM merged
record "SIGTERM after the merge, the group access in flight: exactly 143, the same note" "143/1/0" "$rc/$(notes_n "$merged_note")/$intr_left"
interrupt INT switching
record "Ctrl-C after the merge, the CI_RUNNER write in flight: exactly 130, the same note" "130/1/0/0" \
  "$rc/$(notes_n "$merged_note")/$(called 'X DELETE')/$intr_left"
interrupt TERM switching
record "SIGTERM after the merge, the CI_RUNNER write in flight: exactly 143, the same note" "143/1/0" "$rc/$(notes_n "$merged_note")/$intr_left"

# after the switch: only the optional check is left, and it is cut short
verify_note='interrupted after its work was done (runner group added; routing ready; CI_RUNNER set to local). Only the optional check that the jobs land on the local runner was cut short, and a re-run of the latest run may be in flight.'
interrupt INT verify
record "Ctrl-C while --verify pauses between reads: exactly 130, the sleep taken down, nothing left" "130/0" "$rc/$intr_left"
record "...the note says the repository is routed, only the check was cut short, a re-run may be in flight" "1/no/no" \
  "$(notes_n "$verify_note")/$(has "$out" 'untouched')/$(has "$out" 'may or may not')"
record "...and gives the commands to check by hand, after the note" "yes/yes/yes" \
  "$(has "$out" '  gh run list --repo acme/app --event pull_request --limit 1')/$(has "$out" '  gh run rerun <run-id> --repo acme/app')/$(before "$out" 'interrupted after its work' 'gh run rerun <run-id>')"
record "...the group access and the switch were done once, the branch was not touched" "1/1/0" \
  "$(called "$group_put")/$(called 'variable set CI_RUNNER --repo acme/app --body local')/$(called 'X DELETE')"
interrupt TERM verify
record "SIGTERM while --verify pauses: exactly 143, the same note, the sleep taken down at once" "143/1/0" "$rc/$(notes_n "$verify_note")/$intr_left"

# a second signal while the first one's cleanup runs: the note once, the first
# status, and the run ends at once (a cleanup that hangs can be aborted)
interrupt INT+TERM double
record "Ctrl-C then SIGTERM while the branch is being taken back: the first status, the note once, the branch deleted once" "130/1/1/gone/0" \
  "$rc/$(notes_n "$pr_note")/$(called "$branch_delete")/$([ "$(branch_there)" = yes ] && echo there || echo gone)/$intr_left"
record "...the cleanup said so once, and did not fail" "1/no" \
  "$(notes_n 'removing homefield/route-to-local')/$(has "$out" 'could not remove')"
interrupt INT+INT doublehang
record "a second Ctrl-C while the cleanup hangs ends the run at once (not hung), with the first status" "130/0" "$rc/$intr_left"
record "...the note and the cleanup's line are printed once, the delete was started once" "1/1/1" \
  "$(notes_n "$pr_note")/$(notes_n 'removing homefield/route-to-local')/$(called "$branch_delete")"

# the call that creates the branch is in the cleanup too: gh may finish it (a
# SIGTERM to adopt alone), or be killed before it did (Ctrl-C to the group)
interrupt TERM branch
record "SIGTERM while the branch is being created (gh finishes it): exactly 143, the branch taken back" "143/1/gone/1/no/0" \
  "$rc/$(called "$branch_delete")/$([ "$(branch_there)" = yes ] && echo there || echo gone)/$(notes_n "$pr_note")/$(has "$out" 'could not remove')/$intr_left"
interrupt INT branch
record "Ctrl-C while the branch is being created (gh killed first): exactly 130, a delete tried, the note once, no leaked branch" "130/1/1/gone/0" \
  "$rc/$(called "$branch_delete")/$(notes_n "$pr_note")/$([ "$(branch_there)" = yes ] && echo there || echo gone)/$intr_left"
record "...the delete finds nothing, and says the branch may not have been created" "yes" "$(has "$out" 'could not remove homefield/route-to-local on acme/app (it may not have been created): delete it by hand if it exists')"
adopt GH_REFS_FAIL=1 -- --setup
record "a branch that could not be created is not deleted: the failure only" "nonzero/yes/0/no" \
  "$(nonzero "$rc")/$(has "$out" 'could not create homefield/route-to-local')/$(called 'X DELETE')/$(has "$out" 'removing homefield')"

# a plain adopt installs no handler, so its --verify pause is a foreground
# sleep: a background one would ignore Ctrl-C and outlive adopt, holding its
# output open for whatever reads it
rm -f "$work/jobs-n"
# shellcheck disable=SC2016  # the eval script is expanded by the inner bash
run_fn GH_GROUPS="$work/groups-selected" GH_MEMBERS="$work/members-other" GH_WF="$work/wf-ready" \
  GH_RUNLIST="$work/runlist-done" GH_RUN="$work/run-going" GH_JOBS="$work/jobs-hostonly" ADOPT_VERIFY_INTERVAL=1 ADOPT_VERIFY_TRIES=3 \
  -- eval 'wait() { echo WAITED >>"$CALLS"; builtin wait "$@"; }; cmd_adopt --repo acme/app --verify'
record "a plain adopt's --verify pauses with a foreground sleep: it paused, and waited for no background job" "0/2/0" \
  "$rc/$(called '^sleep 1$')/$(called '^WAITED$')"
# shellcheck disable=SC2016  # the eval script is expanded by the inner bash
run_fn -- eval 'wait() { echo WAITED >>"$CALLS"; builtin wait "$@"; }; ADOPT_HANDLER=1; adopt_nap 0'
record "...while with the handler installed the pause is a background job that is waited for" "1" "$(called '^WAITED$')"

# the parent check: a parent that is a zombie (killed, not yet reaped) still
# answers kill -0, so its state is read
run_fn -- eval 'ps() { echo " Z+ "; }; ADOPT_PARENT_PID=$$; adopt_check_parent'
record "a parent in state Z counts as gone: adopt stops with 143 and says setup ended" "143/yes" "$rc/$(has "$out" 'setup has ended, so adopt stopped')"
run_fn -- eval 'ps() { echo "Ss"; }; ADOPT_PARENT_PID=$$; adopt_check_parent; echo carried-on'
record "...a sleeping parent is not gone" "0/yes" "$rc/$(has "$out" 'carried-on')"
run_fn -- eval 'ADOPT_PARENT_PID=$$; adopt_check_parent; echo carried-on'
record "...nor is one when ps is missing or says nothing" "0/yes" "$rc/$(has "$out" 'carried-on')"
run_fn -- eval 'ADOPT_PARENT_PID=999999; adopt_check_parent'
record "...and a parent that does not exist is gone" "143" "$rc"

# setup's routing step around adopt, signalled in its whole process group: adopt
# says its piece in whatever phase, setup says its own and ends with the status
setup_note='The runner is set up. adopt was interrupted (what it printed above says where things stand and what to run next).'
interrupt INT wait setup
record "setup's routing step, Ctrl-C to the process group: exit 130, no process of the group left" "130/0" "$rc/$intr_left"
record "...adopt's note first, then setup's" "yes/yes/yes" \
  "$(has "$out" "interrupted while waiting for ${pr_url}")/$(has "$out" "$setup_note")/$(before "$out" 'interrupted while waiting' 'The runner is set up.')"
record "...no --setup retry line (the branch exists), nothing removed, nothing switched" "no/0/0/0" \
  "$(has "$out" 'To try again')/$(called 'X DELETE')/$(called "$group_put")/$(called 'variable set')"
record "...the branch and the pull request stay, the temporary directory is gone" "yes/yes" "$(branch_there)/$(tmp_gone)"
interrupt TERM wait setup
record "setup's routing step, SIGTERM to the process group: exit 143, adopt's note, branch kept, no process left" "143/yes/yes/0" \
  "$rc/$(has "$out" "interrupted while waiting for ${pr_url}")/$(branch_there)/$intr_left"
record "...setup traps nothing, so a SIGTERM ends it at once, without its own note" "no" "$(has "$out" 'The runner is set up.')"
interrupt INT pre setup
record "setup's routing step, Ctrl-C before the pull request: 130, adopt's note, the branch taken back, then setup's" "130/1/1/yes/0" \
  "$rc/$(notes_n "$pr_note")/$(called "$branch_delete")/$(before "$out" 'removing homefield/route-to-local' 'The runner is set up.')/$intr_left"
record "...setup's note is there, and it claims no pull request" "yes/no" "$(has "$out" "$setup_note")/$(has "$out" 'is open')"
interrupt INT merged setup
record "setup's routing step, Ctrl-C after the merge: 130, adopt's note, then setup's" "130/1/yes/0" \
  "$rc/$(notes_n "$merged_note")/$(has "$out" "$setup_note")/$intr_left"

# setup killed alone (SIGTERM to its pid, not its group): it dies at once, and
# the adopt it was running must not wait on for the merge. It notices within one
# poll interval (2 s here); the test waits for the group to drain, up to 15 s.
interrupt TERM wait setup-alone
record "setup killed alone while adopt waits: setup ends with 143, and the group drains (adopt does not wait on)" "143/0" "$rc/$intr_left"
record "...adopt says setup ended and that it stopped waiting, with the pull request and branch untouched" "yes/yes/yes" \
  "$(has "$out" "setup has ended, so adopt stopped while waiting for ${pr_url}")/$(has "$out" 'untouched')/$(has "$out" "run: ${plain_cmd}")"
record "...nothing deleted, switched or added to the group, the branch stays, the directory is gone" "0/0/0/yes/yes" \
  "$(called 'X DELETE')/$(called "$group_put")/$(called 'variable set')/$(branch_there)/$(tmp_gone)"
# the same check in the --verify poll, with a stand-in for setup that is ended
interrupt TERM verify parent
record "adopt told its parent is setup, which ends during --verify: adopt stops with 143 and the group drains" "143/0" "$rc/$intr_left"
record "...the note says setup ended, that the repository is routed, and the check by hand" "yes/yes/yes" \
  "$(has "$out" 'setup has ended, so adopt stopped after its work was done (runner group added; routing ready; CI_RUNNER set to local)')/$(has "$out" 'Only the optional check')/$(has "$out" '  gh run rerun <run-id> --repo acme/app')"

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
