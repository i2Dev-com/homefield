#!/usr/bin/env bash
# `homefield setup` (#129): the first-time setup in one command. The real
# cmd_setup / cmd_install run, with stub gh, limactl, uname, scutil and
# sw_vers on a stub-only PATH, and the guest-side steps (isolation probe,
# registered?, token, provisioning, the runner's settings, upgrade) replaced by
# recording functions in a harness, as tests/reset.sh does. What is real: the
# option parsing, preflight's report and gate, the account and runner-group
# steps, the wait for the runner to show online, and the summary. HOME and the
# state directory are temp dirs. Nothing reaches GitHub or a VM.
#
# Run:  bash tests/setup.sh
# shellcheck disable=SC2016  # the stub bodies expand when they run, not when defined
set -uo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

has() { case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac; }
nonzero() { [ "$1" -ne 0 ] && echo nonzero || echo "$1"; }

stubs="$work/stubs"
calls="$work/calls"
provisioned="$work/provisioned"
created_flag="$work/created"
state="$work/state"
mkdir -p "$stubs" "$work/home"

# gh, answering from files and variables, every call recorded. The runners list
# is empty until provisioning has run (the harness creates $PROVISIONED), then
# GH_RUNNERS_AFTER. Group ids: the list is GH_GROUPS (name, visibility, public,
# id; tab separated); the runners in group N are GH_GRPRUN_N (GH_GRPRUN_FAIL
# lists ids whose call fails); its repositories are GH_REPOS (or a failure).
# A group created by a POST ($CREATED) is group 7, and listed afterwards.
# Logged in, `gh auth status` reports "tester|repo" (as the jq filter in
# gh_active_account would print it) when $LOGGED_IN exists, else "|". `gh auth
# login` creates it, unless GH_LOGIN_FAIL makes it fail, or GH_LOGIN_NOOP makes
# it end without logging in.
cat >"$stubs/gh" <<'EOF'
#!/bin/sh
echo "gh $*" >>"$CALLS"
case "$*" in
  "auth status"*)
    # A gh that cannot answer (too old for --json): no output, non-zero.
    [ -z "${GH_STATUS_FAIL:-}" ] || exit 1
    if [ -f "$LOGGED_IN" ]; then echo "tester|repo"; else echo "|"; fi
    ;;
  "auth login"*)
    [ -z "${GH_LOGIN_FAIL:-}" ] || exit 1
    [ -n "${GH_LOGIN_NOOP:-}" ] || : >"$LOGGED_IN"
    ;;
  *"-X POST"*)
    if [ -n "${GH_CREATE_ERR:-}" ]; then echo "$GH_CREATE_ERR" >&2; exit 1; fi
    : >"$CREATED"
    echo '{"id": 7}'
    ;;
  *users/*) echo "${GH_OWNER_TYPE:-Organization}" ;;
  *runner-groups/*/runners*)
    for a in "$@"; do
      case "$a" in *runner-groups/*) gid="${a#*runner-groups/}"; gid="${gid%%/*}" ;; esac
    done
    case " ${GH_GRPRUN_FAIL:-} " in
      *" $gid "*) echo '{"message":"Not Found"}'; exit 1 ;;
    esac
    eval "ids=\${GH_GRPRUN_$gid:-}"
    printf '%b' "$ids"
    ;;
  *runner-groups/*/repositories*)
    if [ -n "${GH_REPOS_FAIL:-}" ]; then echo '{"message":"Not Found"}'; exit 1; fi
    printf '%b' "${GH_REPOS:-}"
    ;;
  *runner-groups*)
    if [ -n "${GH_LIST_FAIL:-}" ]; then echo '{"message":"Must have admin rights"}'; exit 1; fi
    cat "$GH_GROUPS"
    # A group this run created is listed from then on, as GitHub does.
    if [ -f "$CREATED" ]; then printf 'homefield-ci\tselected\tfalse\t7\n'; fi
    ;;
  *actions/runners*)
    if [ -n "${GH_RUNNERS_FAIL:-}" ]; then echo '{"message":"Not Found"}'; exit 1; fi
    if [ -f "$PROVISIONED" ]; then printf '%b' "${GH_RUNNERS_AFTER:-}"; fi
    ;;
esac
EOF
cat >"$stubs/uname" <<'EOF'
#!/bin/sh
case "$1" in -s) echo Darwin ;; -m) echo arm64 ;; esac
EOF
# A Lima with no VM, or one in the state LIMA_STATUS names.
cat >"$stubs/limactl" <<'EOF'
#!/bin/sh
echo "limactl $*" >>"$CALLS"
case "$1" in
  --version) echo "limactl version 2.3.0" ;;
  list)
    echo "other-vm Stopped"
    [ -z "${LIMA_STATUS:-}" ] || echo "homefield ${LIMA_STATUS}"
    ;;
esac
EOF
cat >"$stubs/scutil" <<'EOF'
#!/bin/sh
echo "Test-Mac"
EOF
cat >"$stubs/sw_vers" <<'EOF'
#!/bin/sh
echo "15.0"
EOF
chmod +x "$stubs/gh" "$stubs/uname" "$stubs/limactl" "$stubs/scutil" "$stubs/sw_vers"
for t in awk cat dirname git grep head mktemp mv rm mkdir sed sh sleep tr wc; do ln -s "$(command -v "$t")" "$stubs/$t"; done

# The harness: bin/homefield sourced, with the steps that need a guest replaced.
# PF picks preflight's findings: pass, warn (one warning), fail (one failure),
# login (the gh check from the real login state, as preflight_collect reads it
# through gh_active_account; the rest passes), or real (the real checks,
# against the stub-only PATH, which has no python3 or brew). TTY=1 stands in
# for a terminal.
cat >"$work/harness.sh" <<'EOF'
HOMEFIELD_SOURCE_ONLY=1
. "$ROOT_DIR/bin/homefield"
if [ "${PF:-pass}" != real ]; then
  preflight_collect() {
    PF_NAME=(lima gh)
    PF_LEVEL=(ok ok)
    PF_MSG=("Lima 2.3.0" "gh authenticated as tester")
    case "${PF:-pass}" in
      warn) PF_LEVEL[1]=warn PF_MSG[1]="gh authenticated as tester, no admin:org scope" ;;
      fail) PF_LEVEL[1]=fail PF_MSG[1]="gh not logged in: run 'gh auth login'" ;;
      login)
        acct="$(gh_active_account)" || acct="|"
        if [ -z "${acct%%|*}" ]; then
          PF_LEVEL[1]=fail PF_MSG[1]="gh not logged in: run 'gh auth login'"
        else
          PF_MSG[1]="gh authenticated as ${acct%%|*}"
        fi
        ;;
    esac
  }
fi
have_terminal() { [ "${TTY:-}" = 1 ]; }
verify_isolation() { echo "verify_isolation" >>"$CALLS"; log "isolation verified: no host mounts"; }
is_registered() { [ "${REGISTERED:-no}" = yes ]; }
cmd_upgrade() { echo "cmd_upgrade $*" >>"$CALLS"; log "upgrade ran"; }
get_token() { echo tok123; }
# adopt: records its arguments; ADOPT_FAIL=exit ends it like die does, =return
# fails it, =errexit runs a failing command first (it must not get past it),
# =open and =merged exit with the statuses of a --wait that stopped with the
# pull request open (not merged yet) or merged, =int and =term with Ctrl-C's
# and SIGTERM's.
cmd_adopt() {
  echo "cmd_adopt $*" >>"$CALLS"
  # the pid adopt was told is its parent, and its own $$ (a subshell keeps its
  # parent's, so these are setup's)
  echo "adopt_parent ${ADOPT_PARENT_PID:-none} $$" >>"$CALLS"
  echo "adopt ran"
  case "${ADOPT_FAIL:-}" in
    exit) echo "homefield: adopt: stub refusal" >&2; exit 1 ;;
    return) echo "homefield: adopt: stub failure" >&2; return 1 ;;
    errexit) false; echo "reached" >>"$CALLS" ;;
    open) echo "homefield: adopt: stub wait stopped" >&2; exit 4 ;;
    merged) echo "homefield: adopt: stub failed after the merge" >&2; exit 5 ;;
    int) echo "homefield: interrupted while waiting for the stub" >&2; exit 130 ;;
    term) echo "homefield: interrupted while waiting for the stub" >&2; exit 143 ;;
  esac
}
run_provision() { echo "run_provision" >>"$CALLS"; : >"$PROVISIONED"; }
runner_setting() {
  local k
  for k in "$@"; do
    case "$k" in
      agentName) printf '%s\n' "${STUB_RS_NAME-test-mac-homefield}" ;;
      agentId) printf '%s\n' "${STUB_RS_ID-41}" ;;
    esac
  done
}
"$@"
EOF

printf 'Default\tall\tfalse\t1\nhomefield-ci\tselected\tfalse\t7\n' >"$work/groups-narrow"
printf 'Default\tall\tfalse\t1\n' >"$work/groups-none"
printf 'Default\tall\tfalse\t1\nhomefield-ci\tall\tfalse\t7\n' >"$work/groups-wide"
printf 'Default\tall\tfalse\t1\nhomefield-ci\tselected\tfalse\t7\nother-group\tselected\tfalse\t9\n' >"$work/groups-two"
online=$'test-mac-homefield\tonline\t41\tself-hosted,Linux,ARM64,homefield-ci\n'
offline=$'test-mac-homefield\toffline\t41\tself-hosted,Linux,ARM64,homefield-ci\n'

# srun [VAR=value ...] -- <function> [args]: sets out and rc. No terminal;
# stdin is empty, or the file named by SRUN_IN (the answers to a prompt).
srun() {
  local envs=() logged_in=1
  while [ $# -gt 0 ] && [ "$1" != -- ]; do
    [ "$1" != LOGGED_OUT=1 ] || logged_in=0
    envs+=("$1")
    shift
  done
  shift
  : >"$calls"
  rm -rf "$state" "$provisioned" "$created_flag"
  # gh is logged in unless the case says LOGGED_OUT=1.
  rm -f "$work/logged-in"
  [ "$logged_in" = 0 ] || : >"$work/logged-in"
  out="$(env -i HOME="$work/home" PATH="$stubs" CALLS="$calls" LOGGED_IN="$work/logged-in" PROVISIONED="$provisioned" CREATED="$created_flag" HOMEFIELD_STATE_DIR="$state" \
    ROOT_DIR="$ROOT" ONLINE_WAIT_INTERVAL=0 ONLINE_WAIT_TRIES=3 GH_GROUPS="$work/groups-narrow" \
    GH_RUNNERS_AFTER="$online" GH_GRPRUN_7=$'41\n' "${envs[@]+"${envs[@]}"}" \
    "$BASH" "$work/harness.sh" "$@" 2>&1 <"${SRUN_IN:-/dev/null}")"
  rc=$?
}
called() { grep -c -e "$1" "$calls" || true; }
# marks: how many summary lines start with the check mark / with "!".
marks() { printf '%s\n' "$out" | grep -c "^$1" || true; }
org=https://github.com/acme

# ── the preflight gate ─────────────────────────────────────────────────────
echo "preflight gate"
srun PF=fail -- cmd_setup --url $org
record "setup, a failed check: exit 1, saying nothing was created" "nonzero/yes/yes/yes" \
  "$(nonzero "$rc")/$(has "$out" 'FAIL  gh not logged in')/$(has "$out" 'setup stopped: fix the failed checks above')/$(has "$out" 'nothing was created')"
record "...no Lima call, no gh call, no state file, no VM or group step" "0/0/no/no" \
  "$(called '^limactl')/$(called '^gh')/$([ -e "$state" ] && echo yes || echo no)/$(has "$out" 'creating')"
srun PF=fail -- cmd_install --url $org
record "install, the same failed check: goes on past it (preflight is only a report there)" "0/yes/no/yes" \
  "$rc/$(has "$out" 'FAIL  gh not logged in')/$(has "$out" 'setup stopped')/$([ "$(called 'limactl create')" -gt 0 ] && echo yes || echo no)"
srun PF=warn -- cmd_setup --url $org
record "setup, a warning only: goes on" "0/yes/yes/yes" \
  "$rc/$(has "$out" 'WARN  gh authenticated as tester')/$(has "$out" '✓ VM homefield created (Running)')/$(has "$out" 'Next steps:')"
srun PF=real -- cmd_setup --url $org
record "setup, the real checks on a PATH without python3 or brew: stopped, nothing created" "nonzero/yes/yes/0/0" \
  "$(nonzero "$rc")/$(has "$out" 'FAIL  python3 not found')/$(has "$out" 'nothing was created')/$(called 'limactl create')/$(called '^gh api')"

srun -- cmd_setup --bogus
record "setup, a bad option: refused as setup's, before preflight prints anything" "nonzero/yes/no/no/0" \
  "$(nonzero "$rc")/$(has "$out" 'setup: unknown option --bogus')/$(has "$out" 'All checks passed')/$(has "$out" 'OK')/$(called '.')"
srun PF=fail -- cmd_setup --personal --org
record "setup --personal --org: refused as setup's, before preflight" "nonzero/yes/no" \
  "$(nonzero "$rc")/$(has "$out" 'setup: --personal and --org cannot be used together')/$(has "$out" 'FAIL')"
srun -- cmd_install --bogus
record "install keeps its own name in the same message" "nonzero/yes" "$(nonzero "$rc")/$(has "$out" 'install: unknown option --bogus')"
srun -- main setup --bogus
record "main dispatches setup (and checks its instance)" "nonzero/yes" "$(nonzero "$rc")/$(has "$out" 'setup: unknown option --bogus')"
srun HOMEFIELD_INSTANCE=bad/name -- main setup --url $org
record "...the instance name is checked for setup as for install" "nonzero/yes/0" "$(nonzero "$rc")/$(has "$out" '--instance (or HOMEFIELD_INSTANCE) must be a Lima instance name')/$(called '^limactl')"

# ── gh not logged in: setup offers the login (#146) ────────────────────────
# PF=login reads the gh row from the stub's login state through the real
# gh_active_account, so a login that works turns the failed check into a pass.
echo "gh login offer"
echo y >"$work/answer"
SRUN_IN="$work/answer" srun PF=login LOGGED_OUT=1 TTY=1 -- cmd_setup --url $org
record "logged out, terminal, y, organization URL: gh auth login runs with admin:org, then the checks pass and setup goes on" "0/1/yes/yes/yes" \
  "$rc/$(called '^gh auth login -h github.com -s admin:org$')/$(has "$out" 'OK    gh authenticated as tester')/$(has "$out" 'All checks passed')/$(has "$out" 'Next steps:')"
record "...asked before the preflight report, naming the command and why the scope (#152)" "yes" \
  "$(has "${out%%OK*}" "gh is not logged in. Run 'gh auth login -s admin:org' now? (acme's runner group needs that scope, so you authorize once) [Y/n]")"
# The scope is asked for only where a runner group will need it: an
# organization's owner URL (looked up, or said with --org). Everything else is
# gh's default login, with its own questions.
login_case() { # <description> <expected login call count with -s> <expected plain> <env...> -- <setup args>
  local desc="$1" scoped="$2" plain="$3"
  shift 3
  SRUN_IN="$work/answer" srun PF=login LOGGED_OUT=1 TTY=1 "$@"
  record "$desc" "$scoped/$plain" "$(called '^gh auth login -h github.com -s admin:org$')/$(called '^gh auth login -h github.com$')"
}
login_case "...a trailing slash on the URL is the same" 1 0 -- cmd_setup --url $org/
login_case "--org says it is an organization, whatever the lookup: admin:org" 1 0 GH_OWNER_TYPE=User -- cmd_setup --url $org --org
login_case "--personal says it is not: gh's default login" 0 1 -- cmd_setup --url $org --personal
login_case "a repository URL registers one repository and needs no group: gh's default login" 0 1 -- cmd_setup --url $org/app
login_case "an owner that is a personal account: gh's default login" 0 1 GH_OWNER_TYPE=User -- cmd_setup --url https://github.com/someone
login_case "no URL given (asked after the login): gh's default login" 0 1 -- cmd_setup
SRUN_IN="$work/answer" srun PF=login LOGGED_OUT=1 TTY=1 GH_OWNER_TYPE=User -- cmd_setup --url https://github.com/someone
record "...and its prompt does not mention the scope" "no" "$(has "$out" 'admin:org')"
echo "" >"$work/answer"
SRUN_IN="$work/answer" srun PF=login LOGGED_OUT=1 TTY=1 -- cmd_setup --url $org
record "...just Enter is yes" "0/1" "$rc/$(called '^gh auth login')"
echo n >"$work/answer"
SRUN_IN="$work/answer" srun PF=login LOGGED_OUT=1 TTY=1 -- cmd_setup --url $org
record "logged out, terminal, n: no login; the preflight fails as before and nothing is created" "nonzero/0/yes/yes/yes/0" \
  "$(nonzero "$rc")/$(called '^gh auth login')/$(has "$out" "FAIL  gh not logged in: run 'gh auth login'")/$(has "$out" 'setup stopped: fix the failed checks above')/$(has "$out" 'nothing was created')/$(called 'limactl create')"
SRUN_IN="$work/answer" srun PF=login LOGGED_OUT=1 -- cmd_setup --url $org
record "logged out, no terminal: no question, no login; the same failure" "nonzero/0/no/yes/0" \
  "$(nonzero "$rc")/$(called '^gh auth login')/$(has "$out" '[Y/n]')/$(has "$out" "FAIL  gh not logged in: run 'gh auth login'")/$(called 'limactl create')"
record "...the only login lookup is the preflight report's own" "1" "$(called '^gh auth status')"
echo y >"$work/answer"
SRUN_IN="$work/answer" srun PF=login LOGGED_OUT=1 TTY=1 GITHUB_TOKEN=x -- cmd_setup --url $org
record "GITHUB_TOKEN set: not offered (a login would not change what gh uses), said why" "nonzero/0/no/yes/yes" \
  "$(nonzero "$rc")/$(called '^gh auth login')/$(has "$out" '[Y/n]')/$(has "$out" "'gh auth login' would not help")/$(has "$out" "FAIL  gh not logged in")"
SRUN_IN="$work/answer" srun PF=login LOGGED_OUT=1 TTY=1 GH_TOKEN=x -- cmd_setup --url $org
record "...GH_TOKEN the same" "nonzero/0" "$(nonzero "$rc")/$(called '^gh auth login')"
SRUN_IN="$work/answer" srun PF=login LOGGED_OUT=1 TTY=1 GH_STATUS_FAIL=1 -- cmd_setup --url $org
record "gh that cannot answer (status fails): not offered, a login would not fix it; the same preflight failure" "nonzero/0/no/yes" \
  "$(nonzero "$rc")/$(called '^gh auth login')/$(has "$out" '[Y/n]')/$(has "$out" "FAIL  gh not logged in")"
# Another check failing too (PF=real: no python3 or brew on the stub PATH): the
# browser login would only be followed by the stop, so it is not asked.
SRUN_IN="$work/answer" srun PF=real LOGGED_OUT=1 TTY=1 -- cmd_setup --url $org
record "another check fails as well: no login offered, setup stops on the failures" "nonzero/0/no/yes/yes" \
  "$(nonzero "$rc")/$(called '^gh auth login')/$(has "$out" '[Y/n]')/$(has "$out" 'FAIL  python3 not found')/$(has "$out" 'setup stopped')"
# End of input at the question (Ctrl-D) is not a yes.
: >"$work/eof"
SRUN_IN="$work/eof" srun PF=login LOGGED_OUT=1 TTY=1 -- cmd_setup --url $org
record "end of input at the question: no login, the preflight fails as before" "nonzero/0/yes" \
  "$(nonzero "$rc")/$(called '^gh auth login')/$(has "$out" "FAIL  gh not logged in")"
SRUN_IN="$work/answer" srun PF=login LOGGED_OUT=1 TTY=1 GH_LOGIN_NOOP=1 -- cmd_setup --url $org
record "a login that ends without logging in: still not logged in, the preflight fails as before" "nonzero/1/yes/0" \
  "$(nonzero "$rc")/$(called '^gh auth login')/$(has "$out" "FAIL  gh not logged in: run 'gh auth login'")/$(called 'limactl create')"
SRUN_IN="$work/answer" srun PF=login LOGGED_OUT=1 TTY=1 GH_LOGIN_FAIL=1 -- cmd_setup --url $org
record "a gh auth login that fails: said so, then the same preflight failure (setup does not crash)" "nonzero/1/yes/yes/0" \
  "$(nonzero "$rc")/$(called '^gh auth login')/$(has "$out" "'gh auth login' did not finish")/$(has "$out" 'setup stopped: fix the failed checks above')/$(called 'limactl create')"
SRUN_IN="$work/answer" srun PF=login TTY=1 -- cmd_setup --url $org
record "already logged in, terminal: no question, no login, setup goes on" "0/0/no/yes" \
  "$rc/$(called '^gh auth login')/$(has "$out" '[Y/n]')/$(has "$out" 'Next steps:')"
SRUN_IN="$work/answer" srun PF=login LOGGED_OUT=1 TTY=1 -- cmd_install --url $org
record "install is not offered the login: it goes on past the failed check, as before" "0/0/no/yes" \
  "$rc/$(called '^gh auth login')/$(has "$out" '[Y/n]')/$(has "$out" "FAIL  gh not logged in")"
# gh not installed at all: the PATH has no gh to ask.
mv "$stubs/gh" "$stubs/gh.off"
SRUN_IN="$work/answer" srun PF=pass TTY=1 -- offer_gh_login
record "no gh on the PATH: nothing to offer, nothing asked" "0/no" "$rc/$(has "$out" '[Y/n]')"
mv "$stubs/gh.off" "$stubs/gh"

# ── a fresh setup for an organization ──────────────────────────────────────
echo "fresh setup, organization"
srun GH_GROUPS="$work/groups-none" GH_REPOS='' -- cmd_setup --url $org
record "created group: exit 0" "0" "$rc"
record "...the VM was created" "yes/1" "$(has "$out" '✓ VM homefield created (Running)')/$(called 'limactl create')"
record "...isolation verified" "yes" "$(has "$out" '✓ Isolation verified (no host mounts)')"
record "...the group was created, selected repositories, public off" "yes/1" "$(has "$out" '✓ Runner group homefield-ci created (selected repositories, public off)')/$(called 'POST')"
record "...the runner registered, with its name and id" "yes" "$(has "$out" '✓ Runner registered (test-mac-homefield, id 41)')"
record "...and online, with its labels and its group (confirmed by the group's runner list)" "yes" \
  "$(has "$out" '✓ Runner online (labels: self-hosted Linux ARM64 homefield-ci; group homefield-ci)')"
record "...every summary line is a check mark: none needs attention" "0" "$(marks '!')"
record "...next steps: route a repository, the guide, and the group advice" "yes/yes/yes/yes" \
  "$(has "$out" 'Next steps:')/$(has "$out" '1. Route a repository: homefield adopt --repo <owner>/<repo>')/$(has "$out" '2. See docs/adopting.md for the full guide')/$(has "$out" '3. It is in the runner group homefield-ci')"
record "...nobody can use the new group yet, and it says so" "yes/yes" \
  "$(has "$out" 'Repositories that can use this runner:')/$(has "$out" 'none yet: homefield adopt --repo <owner>/<repo> adds one')"
record "...the group's repositories were asked for by its id" "1" "$(called 'runner-groups/7/repositories')"
record "...install's closing text is not printed" "no" "$(has "$out" 'Registered. Next:')"
record "...the summary comes after the wait for the runner" "yes" \
  "$(has "${out%%✓ VM homefield created*}" 'is online: labels')"
record "...the group was recorded for reset" "group_created=acme/homefield-ci/7" "$(cat "$state/homefield.state" 2>/dev/null)"

srun GH_REPOS=$'acme/app\nacme/api\n' -- cmd_setup --url $org
record "an existing selected group: said to exist, not to be created" "yes/no/0" \
  "$(has "$out" '✓ Runner group homefield-ci exists (selected repositories, public off)')/$(has "$out" 'created (selected')/$(called 'POST')"
record "...its repositories are listed" "yes/yes/no" \
  "$(has "$out" $'Repositories that can use this runner:\n  acme/app\n  acme/api')/$(has "$out" 'acme/api')/$(has "$out" 'none yet')"
record "...from the group's own id" "1" "$(called 'runner-groups/7/repositories')"
srun GH_REPOS_FAIL=1 -- cmd_setup --url $org
record "a repositories list that fails: said so, not shown as empty" "yes/no/0" \
  "$(has "$out" 'could not be listed (gh could not read the runner group')/$(has "$out" 'none yet')/$rc"
record "...and the setup itself is still a success" "0" "$rc"

# ── the other kinds of group ───────────────────────────────────────────────
echo "group variants"
srun GH_GRPRUN_1=$'41\n' -- cmd_setup --url $org --group Default
record "Default: its line, no listing of repositories (it admits every repository)" "yes/yes/0/0/0" \
  "$(has "$out" '✓ Runner group Default (every repository in the organization can use it)')/$(has "$out" 'every repository in acme (the Default group admits them all)')/$(called 'runner-groups/[0-9]*/repositories')/$(called 'POST')/$(marks '!')"
record "...and the Default-group advice" "yes" "$(has "$out" '3. It is in the Default group')"
srun GH_GROUPS="$work/groups-wide" -- cmd_setup --url $org
record "a group wider than recommended: marked, not a check" "yes/no" \
  "$(has "$out" '! Runner group homefield-ci is wider than recommended: narrow it')/$(has "$out" '✓ Runner group homefield-ci')"
record "...no listing, and why; narrowing is the advice" "yes/yes/0/yes" \
  "$(has "$out" 'not listed: this group admits repositories by kind')/$(has "$out" '3. Narrow the runner group homefield-ci as warned above')/$(called 'runner-groups/[0-9]*/repositories')/$(has "$out" 'warning: runner group homefield-ci is wider')"
record "...the runner itself is still reported as online, and the exit is 0" "yes/0" "$(has "$out" '✓ Runner online')/$rc"
srun GH_LIST_FAIL=1 -- cmd_setup --url $org --group-exists
record "an unchecked group: marked" "yes/no" \
  "$(has "$out" '! Runner group homefield-ci was not checked: confirm it by hand')/$(has "$out" '✓ Runner group')"
record "...no listing, and why; checking it is the advice" "yes/yes/0" \
  "$(has "$out" 'who can use it is unknown')/$(has "$out" '3. Check the runner group homefield-ci by hand')/$(called 'runner-groups/[0-9]*/repositories')"
record "...the runner could not be confirmed in a group, and it is not claimed" "no/yes" \
  "$(has "$out" 'group homefield-ci)')/$(has "$out" '✓ Runner online')"
srun GH_OWNER_TYPE=User -- cmd_setup --url https://github.com/someone/app
record "a personal account: no group, registered to the repository" "yes/0/0" \
  "$(has "$out" '✓ Registered to someone/app only (a personal account has no runner groups)')/$(called 'runner-groups')/$(marks '!')"
record "...its repository is the one that can use the runner" "yes" \
  "$(has "$out" $'Repositories that can use this runner:\n  someone/app (this runner is registered to it)')"
record "...online with no group in the line" "yes" "$(has "$out" '✓ Runner online (labels: self-hosted Linux ARM64 homefield-ci)')"
record "...advice that another repository needs its own registration, naming setup" "yes/no" \
  "$(has "$out" '3. It serves only someone/app')/$(has "$out" 'homefield install --instance')"
record "...and says setup, not install, for the other repository" "yes" \
  "$(has "$out" 'homefield setup --instance <name> --url https://github.com/<owner>/<repo>.')"
srun GH_OWNER_TYPE=Organization -- cmd_setup --url https://github.com/acme/app
record "a repository URL: no group either, the repository can use the runner" "yes/yes/0" \
  "$(has "$out" '✓ Registered to acme/app only (a repository has no runner groups)')/$(has "$out" $'Repositories that can use this runner:\n  acme/app (this runner is registered to it)')/$(called 'runner-groups')"

# ── a runner that is not online ────────────────────────────────────────────
echo "runner not online"
srun GH_RUNNERS_AFTER="$offline" -- cmd_setup --url $org
record "offline after the wait: marked, not a check; exit 0" "0/yes/no/yes" \
  "$rc/$(has "$out" '! Runner not online yet (GitHub lists it as: offline): check https://github.com/organizations/acme/settings/actions/runners and homefield status')/$(has "$out" '✓ Runner online')/$(has "$out" '✓ Runner registered (test-mac-homefield, id 41)')"
record "...the wait's own warning is still printed" "yes" "$(has "$out" 'warning: test-mac-homefield is not online after')"
record "...the next steps still follow" "yes" "$(has "$out" 'Next steps:')"
srun GH_RUNNERS_AFTER='' -- cmd_setup --url $org
record "never listed: marked, saying so" "yes/no" "$(has "$out" '! Runner not online yet (GitHub lists it as: not listed yet)')/$(has "$out" '✓ Runner online')"
srun GH_RUNNERS_FAIL=1 -- cmd_setup --url $org
record "the runners list cannot be read: marked as not checked, never as online; exit 0" "0/yes/no" \
  "$rc/$(has "$out" '! Runner online check skipped (GitHub could not be asked)')/$(has "$out" '✓ Runner online')"
srun GH_GROUPS="$work/groups-two" GH_GRPRUN_7='' GH_GRPRUN_9=$'41\n' -- cmd_setup --url $org
record "online, but in another group: the check mark for online, a mark for the group" "yes/yes/no" \
  "$(has "$out" '✓ Runner online (labels: self-hosted Linux ARM64 homefield-ci)')/$(has "$out" '! Runner is in the runner group other-group, not the one asked for')/$(has "$out" 'group homefield-ci)')"
srun GH_GROUPS="$work/groups-two" GH_GRPRUN_FAIL=9 GH_GRPRUN_7='' -- cmd_setup --url $org
record "online, its group cannot be confirmed: said so, not assumed" "yes/yes/no" \
  "$(has "$out" '✓ Runner online (labels: self-hosted Linux ARM64 homefield-ci)')/$(has "$out" '! Its runner group could not be confirmed')/$(has "$out" 'group homefield-ci)')"
srun STUB_RS_NAME= STUB_RS_ID= -- cmd_setup --url $org
record "a registration whose name cannot be read back: marked, no invented name" "yes/no/yes" \
  "$(has "$out" '! Runner registered, but its name could not be read from the VM')/$(has "$out" '✓ Runner registered')/$(has "$out" '! Runner online check skipped')"
srun STUB_RS_ID= -- cmd_setup --url $org
record "no id read back: the name alone, no id invented" "yes/no" "$(has "$out" '✓ Runner registered (test-mac-homefield)')/$(has "$out" ', id ')"

# ── an instance that is already there ──────────────────────────────────────
echo "existing VM and registration"
srun LIMA_STATUS=Running REGISTERED=yes -- cmd_setup
record "registered: it upgrades, as install does" "0/1/0/0" "$rc/$(called 'cmd_upgrade')/$(called 'run_provision')/$(called 'POST')"
record "...the summary: the VM, isolation, and the runner upgraded in place" "yes/yes/yes" \
  "$(has "$out" '✓ VM homefield already existed (Running)')/$(has "$out" '✓ Isolation verified (no host mounts)')/$(has "$out" '✓ Runner test-mac-homefield (id 41) was already registered: upgraded in place')"
record "...no group line, no repositories list, the group was not looked at" "no/no/no/0" \
  "$(has "$out" 'Runner group')/$(has "$out" 'Repositories that can use')/$(has "$out" 'Registered to')/$(called 'runner-groups')"
record "...next steps follow, without group advice" "yes/yes/no" \
  "$(has "$out" 'Next steps:')/$(has "$out" '2. See docs/adopting.md for the full guide')/$(has "$out" 'It is in the')"
srun LIMA_STATUS=Running REGISTERED=yes -- cmd_install
record "install on the same instance: the upgrade, with no summary (as before)" "0/1/no/no/no" \
  "$rc/$(called 'cmd_upgrade')/$(has "$out" '✓')/$(has "$out" 'Next steps')/$(has "$out" 'Registered. Next')"
srun LIMA_STATUS=Stopped REGISTERED=yes -- cmd_setup
record "a stopped VM that was registered: started, and the summary says so" "yes/1" \
  "$(has "$out" '✓ VM homefield already existed (Stopped); started')/$(called 'limactl start')"
srun LIMA_STATUS=Running REGISTERED=yes STUB_RS_ID= -- cmd_setup
record "...an id that cannot be read back is not invented" "yes/no" \
  "$(has "$out" '✓ Runner test-mac-homefield was already registered: upgraded in place')/$(has "$out" '(id')"
srun LIMA_STATUS=Running REGISTERED=no -- cmd_setup --url $org
record "a VM that is there but not registered: registers, the VM line says it existed" "yes/yes/1/0" \
  "$(has "$out" '✓ VM homefield already existed (Running)')/$(has "$out" '✓ Runner registered (test-mac-homefield, id 41)')/$(called 'run_provision')/$(called 'limactl create')"

# ── install is unchanged ───────────────────────────────────────────────────
echo "install output"
srun GH_GROUPS="$work/groups-none" -- cmd_install --url $org
record "install: no check marks, no summary, the closing text it always had" "0/0/no/yes/yes" \
  "$rc/$(marks '✓')/$(has "$out" 'Next steps')/$(has "$out" 'Registered. Next:')/$(has "$out" '  - It is in the runner group homefield-ci, which admits only the
    repositories added to it: homefield adopt --repo <owner>/<repo> adds one.
  - Route jobs from a repository: docs/adopting.md, then
    homefield adopt --repo <owner>/<repo> (group access and the switch).
  - bin/homefield status   shows the runner at any time.')"
record "...it still ends with that text (nothing printed after it)" "bin/homefield status   shows the runner at any time." "$(printf '%s\n' "$out" | tail -1 | sed 's/^  - //')"
srun GH_OWNER_TYPE=User -- cmd_install --url https://github.com/someone/app
record "install, personal: still names install for another repository" "yes/no" \
  "$(has "$out" 'homefield install --instance <name> --url https://github.com/<owner>/<repo>.')/$(has "$out" 'homefield setup --instance')"

# ── the routing pull request offer (#148) ──────────────────────────────────
# After a fresh setup's summary, on a terminal: a repository-scoped
# registration offers adopt --setup --wait for its repository, an organization
# asks which repository first. The harness's cmd_adopt records its arguments.
echo "routing pull request offer"
personal_url=https://github.com/someone/app
echo y >"$work/yes"
echo "" >"$work/enter"
echo n >"$work/no"
printf 'app\n' >"$work/name"
printf 'other/repo\n' >"$work/slugged"
printf 'a b\n' >"$work/bad"
adopt_line() { grep '^cmd_adopt' "$calls" || true; }

SRUN_IN="$work/yes" srun GH_OWNER_TYPE=User TTY=1 -- cmd_setup --url $personal_url
record "personal account, y: adopt runs once, for the repository, with --setup --wait; setup exits 0" "0/1/cmd_adopt --repo someone/app --setup --wait" \
  "$rc/$(called '^cmd_adopt')/$(adopt_line)"
record "...asked after the summary, naming the repository" "yes/yes" \
  "$(has "$out" 'Open the routing pull request for someone/app now, and carry on once you merge it? [Y/n]')/$(has "${out%%Open the routing*}" 'Repositories that can use this runner:')"
record "...adopt's own output follows, and nothing about a failure or a later run" "yes/no/no" \
  "$(has "${out#*Open the routing}" 'adopt ran')/$(has "$out" 'was not opened')/$(has "$out" 'Route it later')"
SRUN_IN="$work/enter" srun GH_OWNER_TYPE=User TTY=1 -- cmd_setup --url $personal_url
record "personal account, just Enter: yes" "0/1/cmd_adopt --repo someone/app --setup --wait" "$rc/$(called '^cmd_adopt')/$(adopt_line)"
record "...adopt is told setup's own pid as its parent, so that it stops if setup is ended alone" "yes" \
  "$(awk '/^adopt_parent/ { print ($2 ~ /^[0-9]+$/ && $2 == $3) ? "yes" : "no (" $2 " vs " $3 ")" }' "$calls")"
SRUN_IN="$work/yes" srun GH_OWNER_TYPE=User TTY=1 -- cmd_setup --url $personal_url --label custom-ci --group my-group
record "--label and --group given: adopt gets both, so the PR routes on the runner's label" "0/1/cmd_adopt --repo someone/app --setup --wait --label custom-ci --group my-group" \
  "$rc/$(called '^cmd_adopt')/$(adopt_line)"
SRUN_IN="$work/no" srun GH_OWNER_TYPE=User TTY=1 -- cmd_setup --url $personal_url --label custom-ci --group my-group
record "...and the command printed for later carries them" "yes" \
  "$(has "$out" 'Route it later with: homefield adopt --repo someone/app --setup --wait --label custom-ci --group my-group')"
SRUN_IN="$work/yes" srun GH_OWNER_TYPE=User TTY=1 ADOPT_FAIL=exit -- cmd_setup --url $personal_url --label custom-ci
record "...and so does the retry line after a failure; no --group when none was given" "yes/no" \
  "$(has "$out" 'To try again: homefield adopt --repo someone/app --setup --wait --label custom-ci')/$(has "$out" '--group')"
SRUN_IN="$work/no" srun GH_OWNER_TYPE=User TTY=1 -- cmd_setup --url $personal_url
record "personal account, n: adopt is not run; one line with the command for later; exit 0" "0/0/yes/no" \
  "$rc/$(called '^cmd_adopt')/$(has "$out" 'Route it later with: homefield adopt --repo someone/app --setup --wait')/$(has "$out" 'adopt ran')"
SRUN_IN="$work/yes" srun GH_OWNER_TYPE=Organization TTY=1 -- cmd_setup --url https://github.com/acme/app
record "a repository URL, y: the repository from the URL" "0/1/cmd_adopt --repo acme/app --setup --wait" "$rc/$(called '^cmd_adopt')/$(adopt_line)"
: >"$work/eof"
SRUN_IN="$work/eof" srun GH_OWNER_TYPE=User TTY=1 -- cmd_setup --url $personal_url
record "repository question, end of input: a no; adopt not run; exit 0, the reminder printed" "0/0/yes" \
  "$rc/$(called '^cmd_adopt')/$(has "$out" 'Route it later with: homefield adopt --repo someone/app --setup --wait')"

SRUN_IN="$work/name" srun TTY=1 -- cmd_setup --url $org
record "organization, a bare name: <org>/<name>, with --setup --wait" "0/1/cmd_adopt --repo acme/app --setup --wait" "$rc/$(called '^cmd_adopt')/$(adopt_line)"
record "...asked after the summary" "yes/yes" \
  "$(has "$out" 'Repository to route first (name or owner/repo; Enter to skip): ')/$(has "${out%%Repository to route first*}" 'Repositories that can use this runner:')"
SRUN_IN="$work/slugged" srun TTY=1 -- cmd_setup --url $org
record "organization, owner/repo: used as typed" "0/1/cmd_adopt --repo other/repo --setup --wait" "$rc/$(called '^cmd_adopt')/$(adopt_line)"
SRUN_IN="$work/enter" srun TTY=1 -- cmd_setup --url $org
record "organization, Enter: skipped quietly, with the command for later" "0/0/yes/no" \
  "$rc/$(called '^cmd_adopt')/$(has "$out" 'Route it later with: homefield adopt --repo <owner>/<repo> --setup --wait')/$(has "$out" 'not a repository')"
SRUN_IN="$work/bad" srun TTY=1 -- cmd_setup --url $org
record "organization, text that is no repository: not run, said so; exit 0" "0/0/yes/yes" \
  "$rc/$(called '^cmd_adopt')/$(has "$out" 'not a repository name or owner/repo: a b; no pull request was opened')/$(has "$out" 'Route it later with')"
SRUN_IN="$work/eof" srun TTY=1 -- cmd_setup --url $org
record "organization, end of input: skipped; exit 0" "0/0/yes" \
  "$rc/$(called '^cmd_adopt')/$(has "$out" 'Route it later with')"

SRUN_IN="$work/yes" srun GH_OWNER_TYPE=User -- cmd_setup --url $personal_url
record "no terminal: no question, adopt not run, only the printed next steps" "0/0/no/no/yes" \
  "$rc/$(called '^cmd_adopt')/$(has "$out" '[Y/n]')/$(has "$out" 'Route it later')/$(has "$out" 'Next steps:')"
SRUN_IN="$work/name" srun -- cmd_setup --url $org
record "...an organization too" "0/0/no" "$rc/$(called '^cmd_adopt')/$(has "$out" 'Repository to route first')"

SRUN_IN="$work/yes" srun GH_OWNER_TYPE=User TTY=1 ADOPT_FAIL=exit -- cmd_setup --url $personal_url
record "adopt dies (exit): setup still exits 0, says the PR was not opened and how to retry" "0/1/yes/yes" \
  "$rc/$(called '^cmd_adopt')/$(has "$out" 'The runner is set up. The routing pull request was not opened (adopt says why above).')/$(has "$out" 'To try again: homefield adopt --repo someone/app --setup --wait')"
record "...adopt's message and the summary are both before the retry line" "yes/yes" \
  "$(has "${out%%The runner is set up*}" 'stub refusal')/$(has "${out%%The runner is set up*}" '✓ Runner registered')"
SRUN_IN="$work/slugged" srun TTY=1 ADOPT_FAIL=return -- cmd_setup --url $org
record "adopt fails (return 1), organization: exit 0 and the retry line names that repository" "0/yes" \
  "$rc/$(has "$out" 'To try again: homefield adopt --repo other/repo --setup --wait')"
SRUN_IN="$work/yes" srun GH_OWNER_TYPE=User TTY=1 ADOPT_FAIL=errexit -- cmd_setup --url $personal_url
record "adopt runs with errexit on: a failing command inside it stops it (not tested in an || context)" "0/0/yes" \
  "$rc/$(called '^reached')/$(has "$out" 'To try again:')"

# adopt --wait stopped after the pull request was opened (#156): no --setup
# retry line (the branch exists), and setup still succeeds
SRUN_IN="$work/yes" srun GH_OWNER_TYPE=User TTY=1 ADOPT_FAIL=open -- cmd_setup --url $personal_url
record "adopt --wait stopped with the pull request open (exit 4): setup exits 0 and says so" "0/yes/yes/no/no" \
  "$rc/$(has "$out" 'The runner is set up. The routing pull request is open; adopt stopped waiting for it (what it printed above says what to run next).')/$(has "$out" 'stub wait stopped')/$(has "$out" 'To try again')/$(has "$out" 'was not opened')"
record "...adopt's message and the summary both come first" "yes/yes" \
  "$(has "${out%%The runner is set up. The routing pull request is open*}" 'stub wait stopped')/$(has "${out%%The runner is set up. The routing pull request is open*}" '✓ Runner registered')"
SRUN_IN="$work/yes" srun GH_OWNER_TYPE=User TTY=1 ADOPT_FAIL=merged -- cmd_setup --url $personal_url --label custom-ci
record "adopt failed after the merge (exit 5): setup exits 0, says merged, names the plain adopt with the runner's label, no --setup" "0/yes/yes/no/no" \
  "$rc/$(has "$out" 'The routing pull request was merged but adopt did not finish switching the repository (what it printed above says why); run: homefield adopt --repo someone/app --label custom-ci')/$(has "$out" 'stub failed after the merge')/$(has "$out" 'To try again')/$(has "$out" 'is open')"
record "...the line is the plain adopt, not the command the offer ran" "no" "$(has "$out" 'run: homefield adopt --repo someone/app --setup')"
SRUN_IN="$work/yes" srun GH_OWNER_TYPE=User TTY=1 ADOPT_FAIL=merged -- cmd_setup --url $personal_url --group 'my group'
record "...and the group it joined, quoted, so the plain adopt does not look at homefield-ci instead" "yes/no" \
  "$(has "$out" 'run: homefield adopt --repo someone/app --group my\ group')/$(has "$out" '--label')"
SRUN_IN="$work/slugged" srun TTY=1 ADOPT_FAIL=open -- cmd_setup --url $org
record "...the open kind names no retry command, an organization too" "0/yes/no" \
  "$rc/$(has "$out" 'The routing pull request is open; adopt stopped waiting for it')/$(has "$out" 'To try again')"
# Ctrl-C: the same note as open, and setup ends with the signal's status
SRUN_IN="$work/yes" srun GH_OWNER_TYPE=User TTY=1 ADOPT_FAIL=int -- cmd_setup --url $personal_url
record "adopt interrupted (130): setup says adopt was interrupted, claims no state of the pull request, no retry, exits 130" "130/yes/no/yes/no" \
  "$rc/$(has "$out" 'The runner is set up. adopt was interrupted (what it printed above says where things stand and what to run next).')/$(has "$out" 'is open')/$(has "$out" 'interrupted while waiting for the stub')/$(has "$out" 'To try again')"
SRUN_IN="$work/yes" srun GH_OWNER_TYPE=User TTY=1 ADOPT_FAIL=term -- cmd_setup --url $personal_url
record "adopt terminated (143): setup says so too and exits 143" "143/yes" \
  "$rc/$(has "$out" 'The runner is set up. adopt was interrupted (what it printed above says where things stand and what to run next).')"
# a status other than 4, 5, 130 and 143 is a run that opened nothing
SRUN_IN="$work/yes" srun GH_OWNER_TYPE=User TTY=1 ADOPT_FAIL=exit -- cmd_setup --url $personal_url
record "adopt exit 1: the 'not opened' message and the retry with --wait; not the open or merged ones" "0/yes/yes/no/no" \
  "$rc/$(has "$out" 'The routing pull request was not opened')/$(has "$out" 'To try again: homefield adopt --repo someone/app --setup --wait')/$(has "$out" 'is open')/$(has "$out" 'was merged')"

SRUN_IN="$work/yes" srun LIMA_STATUS=Running REGISTERED=yes TTY=1 -- cmd_setup --url $personal_url
record "an already registered instance (the upgrade summary), even with --url: no offer" "0/0/no/no/yes" \
  "$rc/$(called '^cmd_adopt')/$(has "$out" 'Open the routing pull request')/$(has "$out" 'Repository to route first')/$(has "$out" 'Next steps:')"
SRUN_IN="$work/yes" srun GH_OWNER_TYPE=User TTY=1 -- cmd_install --url $personal_url
record "install is not offered it" "0/0/no" "$rc/$(called '^cmd_adopt')/$(has "$out" 'Open the routing pull request')"

summary
