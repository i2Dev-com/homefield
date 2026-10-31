#!/usr/bin/env bash
# `homefield diagnose` (#126): the one read-only report over the VM, the runner
# group on GitHub's side and the prerequisites, with the fix for each problem
# it finds, and its --json form.
#
# The real bin/homefield runs, through main, with a PATH that holds only stubs
# (limactl, gh, uname, ...): nothing reaches a VM, GitHub or the real machine,
# and what this Mac has installed never matters. The limactl stub is the
# guest: the probes that diagnose shares with install and status (the mount
# check, `test -e`, `test -f`) are the code's own scripts, executed here
# against a temp directory standing in for the guest's file system, so what
# they print is their own verdict; only commands that need a real guest
# (the runner's settings, the npm probe, the package list) are answered from
# the environment. gh answers the rows its --jq filters would produce, and
# one case applies the filters themselves to API-shaped JSON when jq exists.
#
# Run:  bash tests/diagnose.sh
set -uo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

BASH_BIN="$(command -v bash)"
stubs="$work/stubs"
calls="$work/calls"
allcalls="$work/allcalls"
root="$work/guest"
home="$work/home"
mkdir -p "$stubs" "$home"
: >"$allcalls"

for t in awk cat dirname grep mktemp rm sh sleep tr; do ln -s "$(command -v "$t")" "$stubs/$t"; done

# A Lima with one other VM, and this one when LIMA_STATUS is set. Every call
# is logged. `shell` is the guest: see the header.
cat >"$stubs/limactl" <<'EOF'
#!/bin/sh
echo "limactl $*" >>"$CALLS"
case "$1" in
  --version) echo "limactl version ${LIMA_VERSION:-2.2.0}" ;;
  list)
    if [ -n "${LIMA_LIST_FAIL:-}" ]; then echo "limactl: list failed" >&2; exit 1; fi
    echo "other-vm Stopped"
    [ -z "${LIMA_STATUS:-}" ] || echo "homefield ${LIMA_STATUS}"
    ;;
  start | stop | create | delete | edit) echo "limactl stub: $1 must never be called by diagnose" >&2; exit 98 ;;
  shell)
    shift 4
    if [ -n "${LIMA_SHELL_FAIL:-}" ]; then echo "limactl: could not connect" >&2; exit 1; fi
    [ "$1" != sudo ] || shift
    case "$1" in
      sh)
        script="$3"
        case "$script" in
          *'$(mount)'*) exec "$@" ;;
          *'test -e'*) exec sh -c "$script" sh "$FAKE_ROOT$5" ;;
          *'test -f'*)
            if [ -n "${LIMA_REG_FAIL:-}" ]; then echo "limactl: could not connect" >&2; exit 1; fi
            exec sh -c "$script" sh "$FAKE_ROOT$5"
            ;;
          *extra-packages*) printf '%s' "${GUEST_PKGS-}" ;;
          *node20*) echo "${NPM_OUT:-ok}" ;;
          *) echo "limactl stub: unexpected sh -c: $script" >&2; exit 99 ;;
        esac
        ;;
      python3) printf '%b' "${SETTING_OUT-}" ;;
      cat) exec cat "$FAKE_ROOT$2" ;;
      systemctl) exit "${SVC_ACTIVE:-0}" ;;
      *) echo "limactl stub: unexpected guest command: $*" >&2; exit 99 ;;
    esac
    ;;
esac
EOF
# gh answers the rows the code's --jq filters would produce: the runners GitHub
# lists (GH_RUNNERS: id, status, busy), the groups (GH_GROUPS), the runners of
# a group (GH_GRP_<id>) and a group's repositories (GH_REPOS), each failing on its own switch. GH_SLEEP=1 black-holes the call.
cat >"$stubs/gh" <<'EOF'
#!/bin/sh
echo "gh $*" >>"$CALLS"
case "$*" in
  "auth status --json hosts"*) echo "${GH_JQ_OUT-stub-user|admin:org, repo}" ;;
  *"-X "*) echo "gh stub: a write must never be called by diagnose" >&2; exit 98 ;;
  *"/actions/runners?"*)
    if [ -n "${GH_SLEEP:-}" ]; then sleep 3; fi
    [ -z "${GH_RUNNERS_FAIL:-}" ] || exit 1
    printf '%b' "${GH_RUNNERS-}"
    ;;
  *"/runner-groups?"*)
    [ -z "${GH_GROUPS_FAIL:-}" ] || exit 1
    printf '%b' "${GH_GROUPS-}"
    ;;
  *"/runner-groups/"*"/runners?"*)
    # The ids of the runners in one group: GH_GRP_<group id>, or a failure.
    # (the stub-only PATH has no sed: plain parameter expansion)
    all="$*"
    rest="${all#*/runner-groups/}"
    gid="${rest%%/*}"
    [ -z "${GH_GRP_FAIL:-}" ] || exit 1
    eval "ids=\${GH_GRP_$gid-}"
    printf '%b' "$ids"
    ;;
  *"/repositories?"*)
    [ -z "${GH_REPOS_FAIL:-}" ] || exit 1
    printf '%b' "${GH_REPOS-}"
    ;;
  *) echo "gh stub: unexpected call: $*" >&2; exit 99 ;;
esac
EOF
cat >"$stubs/python3" <<'EOF'
#!/bin/sh
echo "Python 3.12.0"
EOF
cat >"$stubs/brew" <<'EOF'
#!/bin/sh
echo "Homebrew 4.3.0"
EOF
cat >"$stubs/uname" <<'EOF'
#!/bin/sh
case "$1" in
  -s) echo "${FAKE_UNAME_S:-Darwin}" ;;
  -m) echo "${FAKE_UNAME_M:-arm64}" ;;
esac
EOF
cat >"$stubs/sw_vers" <<'EOF'
#!/bin/sh
echo "26.6.2"
EOF
# What `mount` prints in the guest (MOUNT_OUT), or fails (MOUNT_FAIL).
cat >"$stubs/mount" <<'EOF'
#!/bin/sh
[ -z "${MOUNT_FAIL:-}" ] || { echo "mount: cannot read /proc/mounts" >&2; exit 1; }
printf '%s\n' "${MOUNT_OUT:-proc on /proc type proc (rw)}"
EOF
chmod +x "$stubs/limactl" "$stubs/gh" "$stubs/python3" "$stubs/brew" "$stubs/uname" "$stubs/sw_vers" "$stubs/mount"

has() { case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac; }

# guest [registered|unregistered] [SEES_USERS]: the guest's file system under
# $root. A registered runner has .runner, a service name and a version.
guest_fs() {
  rm -rf "$root"
  mkdir -p "$root/opt/actions-runner"
  if [ "${1:-registered}" = registered ]; then
    echo '{}' >"$root/opt/actions-runner/.runner"
    printf '%s' 'actions.runner.acme.test.service' >"$root/opt/actions-runner/.service"
    printf '%s' '2.338.0' >"$root/opt/actions-runner/.provisioned-version"
  fi
  if [ "${2:-}" = SEES_USERS ]; then mkdir -p "$root/Users"; fi
}

org_settings='my-mac-homefield\nhttps://github.com/acme\n42\n'
# One run of diagnose with the stubs as PATH: out (stdout), err (stderr), rc.
# diag [VAR=value ...] -- [diagnose arguments]
diag() {
  local envs=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do
    envs+=("$1")
    shift
  done
  shift
  : >"$calls"
  out="$(env -i HOME="$home" PATH="${STUBS:-$stubs}" CALLS="$calls" FAKE_ROOT="$root" HOMEFIELD_GH_TIMEOUT=5 \
    LIMA_STATUS=Running SETTING_OUT="$org_settings" "${envs[@]+"${envs[@]}"}" \
    "$BASH_BIN" "$ROOT/bin/homefield" diagnose "$@" 2>"$work/err" </dev/null)"
  rc=$?
  err="$(cat "$work/err")"
  cat "$calls" >>"$allcalls"
}
called() { grep -c -e "$1" "$calls" || true; }

# A healthy organization runner in the group homefield-ci, which admits two
# repositories.
org_groups='Default\tall\tfalse\t1\nhomefield-ci\tselected\tfalse\t7\n'
healthy=(GH_RUNNERS='41\tonline\ttrue\n42\tonline\tfalse\n' GH_GROUPS="$org_groups" GH_GRP_1='' GH_GRP_7='41\n42\n'
  GH_REPOS='acme/app\nacme/web\n' GUEST_PKGS='libpq-dev ')

echo "healthy:"
guest_fs
diag "${healthy[@]}" --
record "healthy: exits 0 and says so" "0/yes" "$rc/$(has "$out" 'Summary: healthy.')"
record "...the VM, created and Running" "yes/yes" "$(has "$out" 'VM homefield:')/$(has "$out" '  - Created: yes (Running)')"
record "...isolation verified from the guest" "yes" "$(has "$out" '  - Isolation: verified (no host mounts, /Users hidden)')"
record "...registered, with the name, the id and where" "yes" "$(has "$out" '  - Registered: yes (my-mac-homefield, id 42, at https://github.com/acme)')"
record "...listed on GitHub, online and idle" "yes" "$(has "$out" '  - On GitHub: listed (online, idle)')"
record "...the service, the version, the packages and npm" "yes/yes/yes/yes" "$(has "$out" '  - Service: running (actions.runner.acme.test.service)')/$(has "$out" '  - Version: 2.338.0')/$(has "$out" '  - Extra packages: libpq-dev')/$(has "$out" '  - npm: ok')"
record "...the group: selected repositories, public off" "yes" "$(has "$out" '  - Group: homefield-ci (selected repositories, public off)')"
record "...and the repositories in it" "yes" "$(has "$out" '  - Repositories in group: acme/app, acme/web')"
record "...the prerequisites, from preflight's checks" "yes/yes/yes" "$(has "$out" 'Prerequisites:')/$(has "$out" '  - OK    Lima 2.2.0')/$(has "$out" '  - OK    gh authenticated as stub-user (admin:org scope)')"
record "...no problems and no notes" "no/no" "$(has "$out" 'problem')/$(has "$out" 'Note:')"
record "...Summary is the last line" "Summary: healthy." "$(printf '%s\n' "$out" | tail -n 1)"
record "...asked GitHub for the runner, the groups, who is in the runner's group, then its repositories" "1/1/1/1" "$(called 'orgs/acme/actions/runners?')/$(called 'orgs/acme/actions/runner-groups?')/$(called 'orgs/acme/actions/runner-groups/7/runners?')/$(called 'orgs/acme/actions/runner-groups/7/repositories')"
record "...nothing on stderr" "" "$err"

diag "${healthy[@]}" GH_RUNNERS='42\tonline\ttrue\n' --
record "a runner running a job: listed busy, still healthy" "0/yes" "$rc/$(has "$out" '  - On GitHub: listed (online, busy)')"

diag GH_RUNNERS='42\tonline\tfalse\n' GH_GRP_7='42\n' GH_GROUPS="$org_groups" GH_REPOS='' --
record "the group admits no repository yet: still healthy, with the next step" "0/yes/yes/yes" \
  "$rc/$(has "$out" '  - Repositories in group: none (run '"'"'bin/homefield adopt --repo <owner>/<repo>'"'"')')/$(has "$out" 'Summary: healthy.')/$(has "$out" '  Next: no repository is in runner group homefield-ci yet: bin/homefield adopt --repo <owner>/<repo>')"

echo "the VM:"
diag LIMA_STATUS= --
record "no VM: exits 1, says not created" "1/yes" "$rc/$(has "$out" '  - Created: no')"
record "...skips the guest checks, saying why" "yes/no" "$(has "$out" '  - Guest checks: skipped (the VM does not exist)')/$(has "$out" 'Isolation:')"
record "...with the command that creates it" "yes" "$(has "$out" '     Fix: bin/homefield install --instance homefield --url https://github.com/<org>[/<repo>]')"
record "...the group is skipped too, the prerequisites still shown" "yes/yes" "$(has "$out" '  - Group: skipped (the VM does not exist)')/$(has "$out" '  - OK    Lima 2.2.0')"
record "...the guest was never asked, GitHub neither" "0/0" "$(called 'limactl shell')/$(called 'actions/runners')"
record "...Summary names one problem" "yes" "$(has "$out" 'Summary: 1 problem found.')"

guest_fs
diag LIMA_STATUS=Stopped "${healthy[@]}" --
record "stopped VM: exits 1, says Stopped and that diagnose does not start it" "1/yes/yes" "$rc/$(has "$out" '  - Created: yes (Stopped)')/$(has "$out" '  - Guest checks: skipped (the VM is Stopped, and diagnose never starts it)')"
record "...with the command that starts it" "yes" "$(has "$out" '     Fix: limactl start homefield')"
record "...the VM was not started or stopped, and the guest was not even asked" "0/0/0" "$(called '^limactl start')/$(called '^limactl stop')/$(called '^limactl shell')"
record "...GitHub was not asked either" "0" "$(called '^gh api')"

diag LIMA_LIST_FAIL=1 --
record "Lima cannot answer: exits 1, unknown, not 'not created'" "1/yes/no" "$rc/$(has "$out" 'could not ask Lima about VM homefield')/$(has "$out" 'is not created')"
record "...Created: unknown" "yes" "$(has "$out" '  - Created: unknown')"

guest_fs unregistered
diag "${healthy[@]}" --
record "running VM with no runner registered: exits 1, isolation still checked" "1/yes/yes" "$rc/$(has "$out" '  - Registered: no')/$(has "$out" '  - Isolation: verified')"
record "...the rest skipped, saying why" "yes/yes" "$(has "$out" '  - On GitHub: skipped (no runner is registered)')/$(has "$out" '  - npm: skipped (no runner is registered)')"
record "...with the command that registers it" "yes" "$(has "$out" '     Fix: bin/homefield install --instance homefield --url')"
record "...GitHub was not asked" "0" "$(called '^gh api')"

guest_fs
diag "${healthy[@]}" LIMA_SHELL_FAIL=1 --
record "the guest cannot be reached: exits 1, isolation unknown, the rest skipped" "1/yes/yes" "$rc/$(has "$out" '  - Isolation: unknown (could not run the isolation check in VM homefield)')/$(has "$out" '  - Registered: skipped (the VM could not be asked)')"
guest_fs
diag "${healthy[@]}" LIMA_REG_FAIL=1 --
record "...or only the registration question fails: unknown, not 'not registered'" "1/yes/no" "$rc/$(has "$out" '  - Registered: unknown (could not ask the VM)')/$(has "$out" 'Registered: no')"

echo "isolation, run from the guest's own script:"
guest_fs
diag "${healthy[@]}" MOUNT_OUT='mount0 on /Users type virtiofs (rw)' --
record "a host mount: exits 1, BROKEN, with the way out" "1/yes/yes" "$rc/$(has "$out" '  - Isolation: BROKEN (VM homefield has host mounts)')/$(has "$out" 'recreate the VM without host mounts')"
record "...the checks after it still run" "yes" "$(has "$out" '  - Registered: yes (my-mac-homefield')"
guest_fs registered SEES_USERS
diag "${healthy[@]}" --
record "the guest sees /Users: exits 1, BROKEN" "1/yes" "$rc/$(has "$out" '  - Isolation: BROKEN (VM homefield can see /Users)')"
guest_fs
diag "${healthy[@]}" MOUNT_FAIL=1 --
record "mount itself fails: unknown, not 'no host mounts'" "1/yes/no" "$rc/$(has "$out" '  - Isolation: unknown (could not run the isolation check')/$(has "$out" 'Isolation: verified')"

echo "the runner on the VM:"
guest_fs
diag "${healthy[@]}" SVC_ACTIVE=3 --
record "service not running: exits 1 with the command that starts it" "1/yes/yes" "$rc/$(has "$out" '  - Service: NOT running (actions.runner.acme.test.service)')/$(has "$out" '     Fix: limactl shell homefield sudo systemctl start actions.runner.acme.test.service')"
guest_fs
rm -f "$root/opt/actions-runner/.service"
diag "${healthy[@]}" SVC_ACTIVE=3 --
record "...no service installed at all: says so, exits 1" "1/yes" "$rc/$(has "$out" '  - Service: NOT running (no service installed)')"
guest_fs
diag "${healthy[@]}" NPM_OUT=broken --
record "npm broken: exits 1, upgrade is the fix" "1/yes/yes" "$rc/$(has "$out" '  - npm: BROKEN')/$(has "$out" '     Fix: bin/homefield upgrade --instance homefield')"
diag "${healthy[@]}" NPM_OUT=garbage --
record "the npm probe gives no answer: unknown, exits 1" "1/yes" "$rc/$(has "$out" '  - npm: unknown')"
diag "${healthy[@]}" GUEST_PKGS= --
record "no extra packages: none" "yes" "$(has "$out" '  - Extra packages: none')"
rm -f "$root/opt/actions-runner/.provisioned-version"
diag "${healthy[@]}" --
record "no version file: unknown, as status says" "yes" "$(has "$out" '  - Version: unknown')"
diag "${healthy[@]}" SETTING_OUT='my-mac-homefield\n' --
record "settings that cannot be read: a problem, the rest still reported" "1/yes/yes/yes" "$rc/$(has "$out" 'its settings (/opt/actions-runner/.runner) could not be read')/$(has "$out" '  - Service: running')/$(has "$out" '  - On GitHub: skipped (the runner'"'"'s settings could not be read)')"

echo "GitHub (#76, #103):"
guest_fs
diag "${healthy[@]}" GH_RUNNERS='41\tonline\tfalse\n420\tonline\tfalse\n4\tonline\tfalse\n' --
record "registered but GitHub does not list it: exits 1, matching the id whole" "1/yes/no" "$rc/$(has "$out" '  - On GitHub: NOT listed')/$(has "$out" 'listed (online')"
record "...with the way to register it again, under its old name" "yes" "$(has "$out" 'Fix: bin/homefield uninstall --instance homefield --keep-vm, then bin/homefield install --instance homefield --url https://github.com/acme --name my-mac-homefield')"
record "...the group is not looked up for a runner GitHub does not list" "yes/0" "$(has "$out" '  - Group: skipped (GitHub did not list the runner, so its group is unknown)')/$(called 'runner-groups')"
diag "${healthy[@]}" GH_RUNNERS='42\toffline\tfalse\n' --
record "listed but offline: exits 1" "1/yes/yes" "$rc/$(has "$out" '  - On GitHub: listed (offline, idle)')/$(has "$out" 'GitHub lists the runner my-mac-homefield as offline')"
diag "${healthy[@]}" GH_SLEEP=1 HOMEFIELD_GH_TIMEOUT=1 --
record "gh stalls past the timeout: not checked, not a problem" "0/yes/yes" "$rc/$(has "$out" '  - On GitHub: not checked (timed out after 1s; the network may be down)')/$(has "$out" 'Summary: healthy as far as it could be checked.')"
record "...says so as a note, and the rest is still answered from the VM" "yes/yes" "$(has "$out" '  Note: GitHub was not asked: timed out after 1s')/$(has "$out" '  - npm: ok')"
record "...and the group, which needs the same network, is not asked" "0/0" "$(called 'runner-groups')/$(called '/repositories?')"
diag "${healthy[@]}" GH_RUNNERS_FAIL=1 --
record "gh fails: not checked, needing admin access, exit unchanged" "0/yes" "$rc/$(has "$out" '  - On GitHub: not checked (needs gh with admin access to https://github.com/acme)')"
diag "${healthy[@]}" SETTING_OUT='my-mac-homefield\nhttps://github.com/acme\n\n' --
record "no runner id in the settings: not checked, saying why, gh not asked" "0/yes/0" "$rc/$(has "$out" "not checked (no runner id in the VM's settings)")/$(called 'actions/runners')"

echo "the runner group:"
diag "${healthy[@]}" GH_GROUPS='Default\tall\tfalse\t1\nhomefield-ci\tall\tfalse\t7\n' --
record "a group open to every repository: exits 1, with how to narrow it" "1/yes/yes" "$rc/$(has "$out" 'runner group homefield-ci is wider than it should be: every repository in acme can use it')/$(has "$out" 'narrow it to selected repositories with public ones off')"
record "...shown as such, with no list of repositories to ask for" "yes/yes/0" "$(has "$out" '  - Group: homefield-ci (all repositories, public off)')/$(has "$out" '  - Repositories in group: every repository in the organization')/$(called '/repositories?')"
diag "${healthy[@]}" GH_GROUPS='homefield-ci\tprivate\tfalse\t7\n' --
record "a group open to every private repository: exits 1" "1/yes" "$rc/$(has "$out" 'every private repository in acme can use it')"
diag "${healthy[@]}" GH_GROUPS='homefield-ci\tselected\ttrue\t7\n' --
record "selected repositories but public ones allowed: exits 1, public ON" "1/yes/yes" "$rc/$(has "$out" 'wider than it should be: public repositories can use it')/$(has "$out" '  - Group: homefield-ci (selected repositories, public on)')"
record "...the repositories are still listed" "yes" "$(has "$out" '  - Repositories in group: acme/app, acme/web')"
diag "${healthy[@]}" GH_RUNNERS='42\tonline\tfalse\n' GH_GRP_1='42\n' GH_GRP_7='' --
record "the Default group: a note, not a problem (the Free plan has nothing else)" "0/yes/no" "$rc/$(has "$out" '  Note: runner group Default: every repository in acme can use it; right only if you trust every repository')/$(has "$out" 'Summary: 1 problem')"
diag "${healthy[@]}" GH_RUNNERS='42\tonline\tfalse\n' GH_GRP_1='42\n' GH_GRP_7='' GH_GROUPS='Default\tall\ttrue\t1\n' --
record "...unless it allows public repositories: then it is a problem" "1/yes" "$rc/$(has "$out" 'runner group Default is wider than it should be: every repository in acme can use it, and public repositories can use it')"
diag "${healthy[@]}" GH_GROUPS_FAIL=1 --
record "gh cannot list the groups: a note with the scope to add, not a problem" "0/yes/yes" "$rc/$(has "$out" '  - Group: not checked (gh could not list the runner groups of acme')/$(has "$out" 'gh auth refresh -h github.com -s admin:org')"
diag "${healthy[@]}" GH_GRP_7='41\n' --
record "the runner is in none of the groups listed: not checked, a note" "0/yes/yes/0" "$rc/$(has "$out" "the runner (id 42) is in none of the runner groups gh listed for acme")/$(has "$out" '  Note: runner group not checked')/$(called '/repositories?')"
diag "${healthy[@]}" GH_GRP_FAIL=1 --
record "gh cannot list any group's runners: not checked, a note naming that" "0/yes/0" "$rc/$(has "$out" 'gh could not list the runners of every runner group in acme')/$(called '/repositories?')"
diag "${healthy[@]}" GH_REPOS_FAIL=1 --
record "gh cannot list the group's repositories: the group is shown, the list not checked" "0/yes/yes" "$rc/$(has "$out" '  - Group: homefield-ci (selected repositories, public off)')/$(has "$out" '  - Repositories in group: not checked (gh could not list the repositories of runner group homefield-ci)')"

echo "a repository-scoped registration:"
repo_rows=(GH_RUNNERS='42\tonline\tfalse\n' SETTING_OUT='my-mac-homefield\nhttps://github.com/acme/app\n42\n')
diag "${repo_rows[@]}" --
record "no runner groups: n/a, not an error, exits 0" "0/yes/yes" "$rc/$(has "$out" '  - Group: n/a (repository-scoped registration)')/$(has "$out" 'Summary: healthy.')"
record "...GitHub asked for the repository's runners, and for no group" "1/0" "$(called 'repos/acme/app/actions/runners?')/$(called 'runner-groups')"
record "...and the runner is reported listed" "yes" "$(has "$out" '  - On GitHub: listed (online, idle)')"

echo "prerequisites (preflight's checks):"
guest_fs
nogh="$work/stubs-nogh"
mkdir -p "$nogh"
cp -P "$stubs"/* "$nogh"/
rm -f "$nogh/gh"
STUBS="$nogh" diag "${healthy[@]}" --
record "gh missing: exits 1, FAIL with preflight's own message and fix" "1/yes/yes" "$rc/$(has "$out" "  - FAIL  gh (GitHub CLI) not found: run 'brew install gh'")/$(has "$out" "  1. gh (GitHub CLI) not found: run 'brew install gh'")"
record "...GitHub not asked, the VM still checked" "yes/yes" "$(has "$out" '  - On GitHub: not checked (needs gh with admin access')/$(has "$out" '  - Isolation: verified')"
nolima="$work/stubs-nolima"
mkdir -p "$nolima"
cp -P "$stubs"/* "$nolima"/
rm -f "$nolima/limactl"
STUBS="$nolima" diag "${healthy[@]}" --
record "Lima missing: exits 1, one problem, the VM unknown" "1/yes/yes/yes" "$rc/$(has "$out" "  - FAIL  Lima not found: run 'brew install lima'")/$(has "$out" '  - Guest checks: skipped (Lima is not installed)')/$(has "$out" 'Summary: 1 problem found.')"
diag "${healthy[@]}" GH_JQ_OUT='person|repo, read:org' --
record "a gh token without admin:org: WARN in the prerequisites, not a problem, exit 0" "0/yes/yes" "$rc/$(has "$out" '  - WARN  gh authenticated as person, no admin:org scope')/$(has "$out" 'Summary: healthy.')"
diag "${healthy[@]}" FAKE_UNAME_S=Linux --
record "not macOS: FAIL in the prerequisites, exits 1" "1/yes" "$rc/$(has "$out" '  - FAIL  needs macOS (Darwin): found Linux')"

echo "options:"
diag "${healthy[@]}" -- --bogus
record "an unknown option dies like the other commands, saying so on stderr" "1/diagnose: unknown option --bogus (see bin/homefield help)/" "$rc/${err#homefield: }/$out"
diag "${healthy[@]}" -- extra
record "a stray argument too" "1/yes" "$rc/$(has "$err" 'diagnose: unknown option extra')"
diag "${healthy[@]}" -- --json --bogus
record "...--json beside it changes nothing: still dies, prints no JSON" "1/" "$rc/$out"
diag "${healthy[@]}" HOMEFIELD_INSTANCE='bad name' --
record "an invalid instance name is refused before anything runs" "1/yes/0" "$rc/$(has "$err" 'must be a Lima instance name')/$(called 'limactl')"
out="$(env -i HOME="$home" PATH="$stubs" CALLS="$calls" "$BASH_BIN" "$ROOT/bin/homefield" help 2>&1 </dev/null)"
record "help lists diagnose and its --json" "yes/yes" "$(has "$out" '  diagnose   One read-only report')/$(has "$out" 'diagnose:
  --json')"

# ── json_str itself ─────────────────────────────────────────────────────────
echo "json_str:"
# shellcheck disable=SC2016 # the script is for the child bash to expand
js() { HOMEFIELD_SOURCE_ONLY=1 "$BASH_BIN" -c '. "$1"; json_str "$2"' _ "$ROOT/bin/homefield" "$1"; }
record "quote" '"a\"b"' "$(js 'a"b')"
record "backslash" '"a\\b"' "$(js 'a\b')"
record "backslash before a quote" '"\\\""' "$(js '\"')"
record "newline" '"a\nb"' "$(js $'a\nb')"
record "carriage return and tab" '"a\rb\tc"' "$(js $'a\rb\tc')"
record "other control characters" '"\u0001\u001f\u007f"' "$(js $'\001\037\177')"
record "UTF-8 passes through" '"é 日本"' "$(js 'é 日本')"
record "empty" '""' "$(js '')"

# Real python3 only: on a stock Mac `python3` is a stub that opens an
# installer dialog, and the stubs above must not stand in for it here.
real_python=""
if command -v python3 >/dev/null 2>&1 && python3 -c 'import json' >/dev/null 2>&1; then real_python=1; fi
if [ -z "$real_python" ]; then
  echo "  SKIP the --json cases that parse the output: no working python3 on PATH (json_str's literal escapes above still ran)"
else
  parse() { python3 -c "$1" <<<"$out"; }
  # python3 runs on the real PATH here, not the stubs'.
  round_trip() {
    local value="$1" lit
    lit="$(js "$value")"
    printf '%s' "$value" >"$work/rt-value"
    printf '%s' "$lit" >"$work/rt-json"
    python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[2], encoding="utf-8")) == open(sys.argv[1], encoding="utf-8", newline="").read() else 1)' "$work/rt-value" "$work/rt-json"
    echo $?
  }
  record "json_str round-trips awkward values through a JSON parser" "0/0/0/0/0/0" \
    "$(round_trip 'q"uote')/$(round_trip $'back\\slash\\\\')/$(round_trip $'line\nbreak\r\n')/$(round_trip $'tab\there\001\002\037')/$(round_trip $'\177del')/$(round_trip '"} , {"healthy": true')"

  echo "--json:"
  guest_fs
  diag "${healthy[@]}" -- --json
  record "healthy: exits 0, stdout is one JSON document and nothing else" "0/0" "$rc/$(parse 'import json,sys; json.load(sys.stdin)' >/dev/null 2>&1; echo $?)"
  record "...healthy true, no problems" "True/[]" "$(parse 'import json,sys; d=json.load(sys.stdin); print(d["healthy"], d["problems"], sep="/")')"
  record "...the VM's facts" "True/Running/True/verified/True/my-mac-homefield/42/https://github.com/acme" \
    "$(parse 'import json,sys; v=json.load(sys.stdin)["vm"]; print(v["created"], v["status"], v["guest_checked"], v["isolation"]["state"], v["registered"], v["runner"]["name"], v["runner"]["id"], v["runner"]["url"], sep="/")')"
  record "...GitHub's: listed online idle, service, version, packages, npm" "listed/online/False/running/2.338.0/['libpq-dev']/ok" \
    "$(parse 'import json,sys; v=json.load(sys.stdin)["vm"]; print(v["on_github"]["state"], v["on_github"]["status"], v["on_github"]["busy"], v["service"]["state"], v["version"], v["extra_packages"], v["npm"], sep="/")')"
  record "...the group and its repositories" "organization/checked/homefield-ci/selected/False/['acme/app', 'acme/web']" \
    "$(parse 'import json,sys; g=json.load(sys.stdin)["github"]; print(g["scope"], g["group"]["state"], g["group"]["name"], g["group"]["visibility"], g["group"]["allows_public"], g["group"]["repositories"], sep="/")')"
  record "...the six prerequisites, all ok" "6/ok" "$(parse 'import json,sys; p=json.load(sys.stdin)["prerequisites"]; print(len(p), "/".join(sorted({x["status"] for x in p})), sep="/")')"

  diag "${healthy[@]}" GH_RUNNERS='42\tonline\tfalse\n' GH_REPOS='' -- --json
  record "an empty group: healthy, an empty list, the hint" "True/[]/1" "$(parse 'import json,sys; d=json.load(sys.stdin); print(d["healthy"], d["github"]["group"]["repositories"], len(d["hints"]), sep="/")')"

  diag LIMA_STATUS=Stopped "${healthy[@]}" -- --json
  record "stopped VM: exits 1, healthy false, the problem and its fix" "1/False/vm/limactl start homefield" \
    "$rc/$(parse 'import json,sys; d=json.load(sys.stdin); p=d["problems"][0]; print(d["healthy"], p["check"], p["fix"], sep="/")')"
  record "...guest not checked, the reason, nulls for what was not asked" "False/the VM is Stopped, and diagnose never starts it/None/None/skipped" \
    "$(parse 'import json,sys; v=json.load(sys.stdin)["vm"]; print(v["guest_checked"], v["skipped_reason"], v["registered"], v["extra_packages"], v["npm"], sep="/")')"
  record "...and the VM was not started (the calls say so)" "0/0" "$(called '^limactl start')/$(called '^limactl shell')"

  diag LIMA_STATUS= -- --json
  record "no VM: created false, one problem" "1/False/1" "$rc/$(parse 'import json,sys; d=json.load(sys.stdin); print(d["vm"]["created"], len(d["problems"]), sep="/")')"

  diag "${repo_rows[@]}" -- --json
  record "repository-scoped: scope repository, group n/a with null repositories" "repository/n/a/None" \
    "$(parse 'import json,sys; g=json.load(sys.stdin)["github"]; print(g["scope"], g["group"]["state"], g["group"]["repositories"], sep="/")')"

  diag "${healthy[@]}" GH_SLEEP=1 HOMEFIELD_GH_TIMEOUT=1 -- --json
  record "GitHub timed out: state timed-out, a warning, still healthy" "0/timed-out/True/1" \
    "$rc/$(parse 'import json,sys; d=json.load(sys.stdin); print(d["vm"]["on_github"]["state"], d["healthy"], len(d["warnings"]), sep="/")')"

  # Awkward values in what the report prints: a runner name with a quote, a
  # backslash and a control character, a repository and a group likewise.
  weird_name=$'ru"nn\\er\001'
  weird_group=$'gr"oup\\'
  guest_fs
  diag GH_RUNNERS='41\tonline\tfalse\n' SETTING_OUT='ru"nn\\er\001\nhttps://github.com/acme\n42\n' -- --json
  record "awkward runner name: still valid JSON, and the name round-trips" "0/$weird_name" \
    "$(parse 'import json,sys; json.load(sys.stdin)' >/dev/null 2>&1; echo $?)/$(parse 'import json,sys; print(json.load(sys.stdin)["vm"]["runner"]["name"], end="")')"
  record "...in a problem's text too (the NOT listed fix carries the name)" "True" \
    "$(parse 'import json,sys; d=json.load(sys.stdin); print(any("ru\"nn\\er\x01" in p["fix"] for p in d["problems"]))')"
  guest_fs
  diag GH_RUNNERS='42\tonline\tfalse\n' GH_GRP_7='42\n' GH_GROUPS="Default\tall\tfalse\t1\ngr\"oup\\\\\tselected\tfalse\t7\n" GH_REPOS='acme/a"pp\nacme/b\\c\n' -- --json
  record "awkward group and repository names: valid JSON, round-tripping" "0/$weird_group/['acme/a\"pp', 'acme/b\\\\c']" \
    "$(parse 'import json,sys; json.load(sys.stdin)' >/dev/null 2>&1; echo $?)/$(parse 'import json,sys; g=json.load(sys.stdin)["github"]["group"]; print(g["name"], g["repositories"], sep="/", end="")')"
fi

# ── the gh filters themselves ───────────────────────────────────────────────
# The gh stub answers with the rows the filters would produce, so a typo in a
# filter would pass everything above. With jq, apply the filters diagnose
# actually sent (read back from the call log) to API-shaped JSON.
echo "the --jq filters:"
if ! command -v jq >/dev/null 2>&1; then
  echo "  SKIP the --jq filters are not applied: no jq on PATH"
else
  guest_fs
  diag "${healthy[@]}" --
  runners_filter="$(grep -e 'actions/runners?' "$calls" | head -n 1 | sed 's/.* --jq //')"
  repos_filter="$(grep -e '/repositories?' "$calls" | head -n 1 | sed 's/.* --jq //')"
  # The shape GitHub returns for an organization's runners: no runner_group_id.
  runners_json='{"runners":[{"id":41,"name":"other","os":"Linux","status":"online","busy":true,"labels":[]},{"id":42,"name":"mine","os":"Linux","status":"offline","busy":false,"labels":[]}]}'
  record "runner filter: id, status and busy per runner" $'41\tonline\ttrue|42\toffline\tfalse' \
    "$(printf '%s' "$runners_json" | jq -r "$runners_filter" | tr '\n' '|' | sed 's/|$//')"
  group_runners_filter="$(grep -e 'runner-groups/.*/runners?' "$calls" | head -n 1 | sed 's/.* --jq //')"
  record "group runners filter: the ids" "41|42" \
    "$(printf '%s' '{"total_count":2,"runners":[{"id":41,"name":"other","status":"online","busy":true},{"id":42,"name":"mine","status":"offline","busy":false}]}' | jq -r "$group_runners_filter" | tr '\n' '|' | sed 's/|$//')"
  record "repository filter: full names" "acme/app|acme/web" \
    "$(printf '%s' '{"total_count":2,"repositories":[{"id":1,"full_name":"acme/app"},{"id":2,"full_name":"acme/web"}]}' | jq -r "$repos_filter" | tr '\n' '|' | sed 's/|$//')"
fi

echo "read-only:"
record "no call anywhere started, stopped, created, deleted or edited a VM" "0" "$(grep -c -E '^limactl (start|stop|create|delete|edit)' "$allcalls" || true)"
record "...none changed the runner service, registered or removed it" "0" "$(grep -c -E 'systemctl (start|stop|restart)|config\.sh|svc\.sh|provision\.sh' "$allcalls" || true)"
record "...and gh made no write (-X) call" "0" "$(grep -c -E '^gh .*-X ' "$allcalls" || true)"

summary
