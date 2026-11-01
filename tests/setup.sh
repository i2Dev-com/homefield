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
cat >"$stubs/gh" <<'EOF'
#!/bin/sh
echo "gh $*" >>"$CALLS"
case "$*" in
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
  --version) echo "limactl version 2.2.0" ;;
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
# or real (the real checks, against the stub-only PATH, which has no python3 or
# brew).
cat >"$work/harness.sh" <<'EOF'
HOMEFIELD_SOURCE_ONLY=1
. "$ROOT_DIR/bin/homefield"
if [ "${PF:-pass}" != real ]; then
  preflight_collect() {
    PF_NAME=(lima gh)
    PF_LEVEL=(ok ok)
    PF_MSG=("Lima 2.2.0" "gh authenticated as tester")
    case "${PF:-pass}" in
      warn) PF_LEVEL[1]=warn PF_MSG[1]="gh authenticated as tester, no admin:org scope" ;;
      fail) PF_LEVEL[1]=fail PF_MSG[1]="gh not logged in: run 'gh auth login'" ;;
    esac
  }
fi
verify_isolation() { echo "verify_isolation" >>"$CALLS"; log "isolation verified: no host mounts"; }
is_registered() { [ "${REGISTERED:-no}" = yes ]; }
cmd_upgrade() { echo "cmd_upgrade $*" >>"$CALLS"; log "upgrade ran"; }
get_token() { echo tok123; }
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

# srun [VAR=value ...] -- <function> [args]: sets out and rc. No terminal.
srun() {
  local envs=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do
    envs+=("$1")
    shift
  done
  shift
  : >"$calls"
  rm -rf "$state" "$provisioned" "$created_flag"
  out="$(env -i HOME="$work/home" PATH="$stubs" CALLS="$calls" PROVISIONED="$provisioned" CREATED="$created_flag" HOMEFIELD_STATE_DIR="$state" \
    ROOT_DIR="$ROOT" ONLINE_WAIT_INTERVAL=0 ONLINE_WAIT_TRIES=3 GH_GROUPS="$work/groups-narrow" \
    GH_RUNNERS_AFTER="$online" GH_GRPRUN_7=$'41\n' "${envs[@]+"${envs[@]}"}" \
    "$BASH" "$work/harness.sh" "$@" 2>&1 </dev/null)"
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

summary
