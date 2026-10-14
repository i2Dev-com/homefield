#!/usr/bin/env bash
# `bin/ci-runner adopt` and its helpers: the repository checks, the runner
# group access, the routing check on downloaded workflows, the cache-key
# warnings and the switch. bin/ci-runner is sourced (CI_RUNNER_SOURCE_ONLY=1)
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
ln -s "$(command -v python3)" "$stubs/python3"
cp "$work/gh" "$stubs/gh"

# The group rows are name, visibility, public allowed, id.
printf 'Default\tall\tfalse\t1\nlocal-ci\tselected\tfalse\t42\n' >"$work/groups-selected"
printf 'Default\tall\tfalse\t1\nLocal-CI\tselected\tfalse\t42\n' >"$work/groups-case"
printf 'Default\tall\tfalse\t1\nlocal-ci\tall\tfalse\t42\n' >"$work/groups-all"
printf 'Default\tall\tfalse\t1\nlocal-ci\tprivate\tfalse\t42\n' >"$work/groups-private"
printf 'Default\tall\tfalse\t1\n' >"$work/groups-none"
printf '100\n200\n' >"$work/members-other"
printf '100\n555\n200\n' >"$work/members-with"
: >"$work/members-empty"

# ── Workflow fixtures ──────────────────────────────────────────────────────
expr="$(python3 "$ROOT/verify-routing/verify_routing.py" --print-expression)"
expr_acme="$(python3 "$ROOT/verify-routing/verify_routing.py" --print-expression --label acme-ci)"

# emit_job <id> <runs-on> [extra step lines...]
emit_job() {
  local id="$1" runs="$2" line
  shift 2
  printf '  %s:\n    runs-on: %s\n    steps:\n      - uses: actions/checkout@v5\n' "$id" "$runs"
  for line in "$@"; do printf '%s\n' "$line"; done
}
header() { printf 'name: CI\non: [pull_request]\njobs:\n'; }
# guard <expected block lines> or guard_label <label> <block lines>
guard() {
  printf '      - name: Verify local-runner routing\n        uses: i2Dev-com/ci-runner/verify-routing@v2\n        with:\n          expected: |\n'
  local e
  for e in "$@"; do printf '            %s\n' "$e"; done
}
guard_label() {
  local label="$1"
  shift
  guard "$@"
  printf '          label: %s' "$label"
}
# GitHub expression text, written with the $ escaped so that it is not shell.
os_key="\${{ runner.os }}"
arch_key="\${{ runner.arch }}"
hash_key="\${{ hashFiles('package-lock.json') }}"
cache_step() {
  printf '      - uses: actions/cache@v5\n        with:\n          path: ~/.npm\n          key: %s\n' "$1"
}

mkdir -p "$work/wf-ready" "$work/wf-noguard" "$work/wf-mismatch" "$work/wf-norouted" "$work/wf-label" "$work/wf-cache"
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
  emit_job lint ubuntu-latest "$(printf '      - name: Verify local-runner routing\n        uses: i2Dev-com/ci-runner/verify-routing@v2\n        with:\n          expected: '"''"'')"
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
  out="$(env -i HOME="$work" PATH="$stubs" TMPDIR="$work/tmp" CALLS="$calls" CI_RUNNER_SOURCE_ONLY=1 "${envs[@]+"${envs[@]}"}" \
    "$BASH" -c '. "$1"; shift; "$@"' _ "$ROOT/bin/ci-runner" "$@" 2>&1 </dev/null)"
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
record "selected group, not a member: added" "0/yes" "$rc/$(has "$out" 'added acme/app to local-ci')"
record "...by a PUT to the group's repository path, once" "1" "$(called "gh api -X PUT $put_path")"
record "...after reading the members, paginated" "1" "$(called '--paginate orgs/acme/actions/runner-groups/42/repositories?per_page=100')"

adopt GH_MEMBERS="$work/members-with" --
record "already a member: no PUT" "0/yes/0" "$rc/$(has "$out" 'already has access to local-ci')/$(called 'X PUT')"
adopt GH_MEMBERS="$work/members-empty" --
record "no members at all: added" "1" "$(called 'X PUT')"
adopt GH_GROUPS="$work/groups-case" --
record "the group name is found in any case" "1/yes" "$(called 'X PUT')/$(has "$out" 'added acme/app to Local-CI')"
adopt GH_GROUPS="$work/groups-all" --
record "a group open to all repositories: a warning, no PUT, no members read" "0/yes/yes/0/0" \
  "$rc/$(has "$out" 'warning: runner group local-ci is open to all')/$(has "$out" 'already has access and nothing was added')/$(called 'X PUT')/$(called 'repositories?')"
adopt GH_GROUPS="$work/groups-private" --
record "a group open to private repositories: the same" "0/yes/0" "$rc/$(has "$out" 'open to private repositories')/$(called 'X PUT')"
adopt GH_GROUPS="$work/groups-none" --
record "no such group: a note that nothing was done, and it goes on" "0/yes/0/yes" \
  "$rc/$(has "$out" 'has no group local-ci')/$(called 'X PUT')/$(has "$out" 'routing: ready')"
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
record "the PUT fails: an error naming the manual step" "nonzero/yes" "$(nonzero "$rc")/$(has "$out" 'could not add acme/app to runner group local-ci; add it by hand')"
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
  "$(nonzero "$rc")/$(has "$out" 'routing: not ready')/$(has "$out" 'no verify-routing step in .github/workflows')/$(called 'variable set')"
record "...the canonical expression is printed" "yes" "$(has "$out" "runs-on: $expr")"
record "...and the guard step, with the jobs that are routed" "yes/yes/yes" \
  "$(has "$out" 'uses: i2Dev-com/ci-runner/verify-routing@v2')/$(has "$out" '            ci.yml:lint')/$(has "$out" '            ci.yml:test')"
record "...the default label is not written into the guard" "no" "$(has "$out" 'label: local-ci')"
record "...and the last line says to merge first" "yes" "$(has "$out" 'not switched: merge the routing first, then run ci-runner adopt again')"

adopt GH_WF="$work/wf-mismatch" --
record "a guard that differs from the routed jobs: not ready" "nonzero/yes/yes/0" \
  "$(nonzero "$rc")/$(has "$out" 'would fail')/$(has "$out" 'ci.yml:test opts in but is not in the expected list')/$(called 'variable set')"
adopt GH_WF="$work/wf-norouted" --
record "a guard with no routed job: not ready" "nonzero/yes/0" "$(nonzero "$rc")/$(has "$out" 'no job uses the routing expression')/$(called 'variable set')"
record "...the snippet has a placeholder job" "yes" "$(has "$out" 'ci.yml:<job-id>')"
adopt GH_WF="$work/wf-nonexistent" --
record "no .github/workflows at all: not ready, not an error to look" "nonzero/yes/yes/0" \
  "$(nonzero "$rc")/$(has "$out" 'no verify-routing step')/$(has "$out" 'cache keys: no workflow files')/$(called 'variable set')"
adopt GH_WF="$work/wf-ready" GH_WF_FAIL=1 --
record "the directory cannot be listed (not a 404): an error" "nonzero/yes/0" "$(nonzero "$rc")/$(has "$out" 'could not list .github/workflows in acme/app')/$(called 'variable set')"
adopt GH_WF="$work/wf-noguard" -- --jobs 'a.yml:x,b.yml:y'
record "--jobs fills the snippet's expected list" "yes/yes/no" "$(has "$out" '            a.yml:x')/$(has "$out" '            b.yml:y')/$(has "$out" '            ci.yml:lint')"

adopt GH_WF="$work/wf-label" --
record "a guard with another label: that label is used" "0/yes/1" "$rc/$(has "$out" 'routing: ready')/$(called 'variable set CI_RUNNER --repo acme/app --body local')"
adopt GH_WF="$work/wf-label" -- --label local-ci
record "...unless --label says otherwise: not ready" "nonzero/yes/0" "$(nonzero "$rc")/$(has "$out" 'uses label acme-ci, but --label is local-ci')/$(called 'variable set')"
adopt GH_WF="$work/wf-label" -- --label acme-ci
record "...--label that agrees is fine" "0/1" "$rc/$(called 'variable set CI_RUNNER --repo acme/app --body local')"
adopt GH_WF="$work/wf-noguard" -- --label acme-ci
record "snippets carry the chosen label in the expression and the guard" "yes/yes" "$(has "$out" "runs-on: $expr_acme")/$(has "$out" '          label: acme-ci')"

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
  "$rc/$(has "$out" 'would add acme/app to local-ci (dry run)')/$(has "$out" 'CI_RUNNER hosted -> local (dry run)')/$(called 'X PUT')/$(called 'variable set')"
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
jobs:
  one:
    steps:
      # - uses: x/ci-runner/verify-routing@v2   (commented out)
      - uses: org/ci-runner/verify-routing@v2
        with:
          expected: a.yml:one a.yml:two
  two:
    steps:
      - name: Guard
        with:
          label: "acme-ci"
          expected: "a.yml:one, a.yml:two"
        uses: 'org/ci-runner/verify-routing@v2'
      - uses: actions/checkout@v5
        with:
          expected: not-a-guard
  three:
    steps:
      - name: Guard, comments in and after the block
        uses: org/ci-runner/verify-routing@v2 # pinned
        with:
          expected: |-
            a.yml:one

          # a comment at the key's depth ends the scalar
      - run: echo done
EOF
printf 'jobs:\r\n  j:\r\n    steps:\r\n      - uses: o/r/verify-routing@v3\r\n        with:\r\n          expected: |\r\n            b.yml:j\r\n' >"$shapes/b.yaml"
printf 'jobs:\n  j:\n    steps:\n      - uses: o/r/verify-routing@v2\n' >"$shapes/c.yml"
echo "not a workflow" >"$shapes/d.txt"
got="$(python3 -I "$ROOT/tools/adopt.py" guards "$shapes")"
want="$(printf 'a.yml:5\tlocal-ci\ta.yml:one a.yml:two\na.yml:14\tacme-ci\ta.yml:one a.yml:two\na.yml:21\tlocal-ci\ta.yml:one\nb.yaml:4\tlocal-ci\tb.yml:j\nc.yml:4\tlocal-ci\t')"
record "guards: shapes of the step (block, inline, quoted, uses after with, CRLF, none)" "$want" "$got"
record "guards: a directory with no workflow files has none" "" "$(mkdir -p "$work/empty" && python3 -I "$ROOT/tools/adopt.py" guards "$work/empty")"

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
record "quote: spaces and slashes are encoded" "a%20b%2Fc.yml" "$(python3 -I "$ROOT/tools/adopt.py" quote 'a b/c.yml')"

# ── The docs say what the tool prints ──────────────────────────────────────
echo "docs"
adopting="$(cat "$ROOT/docs/adopting.md")"
readme="$(cat "$ROOT/README.md")"
record "docs/adopting.md has the canonical expression" "yes" "$(has "$adopting" "runs-on: $expr")"
record "README.md has the canonical expression" "yes" "$(has "$readme" "runs-on: $expr")"
pinned="$(python3 -B -I -c 'import sys; sys.path.insert(0, sys.argv[1]); import adopt; print(adopt.ACTION)' "$ROOT/tools")"
record "docs/adopting.md pins the same verify-routing as the snippet" "yes" "$(has "$adopting" "uses: $pinned")"
record "README.md pins the same verify-routing as the snippet" "yes" "$(has "$readme" "uses: $pinned")"

summary
