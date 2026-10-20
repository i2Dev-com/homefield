#!/usr/bin/env bash
# The install steps that talk to GitHub: finding or creating the organization's
# runner group, waiting for the runner to show online, and `version`, plus the
# order of `install`'s checks. bin/homefield is sourced (HOMEFIELD_SOURCE_ONLY=1)
# to call functions on their own, with a stub gh that records its calls and
# answers from files. Nothing reaches GitHub or a VM.
#
# Run:  bash tests/runner-group.sh
set -uo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

has() { case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac; }
nonzero() { [ "$1" -ne 0 ] && echo nonzero || echo "$1"; }

stubs="$work/stubs"
calls="$work/calls"
mkdir -p "$stubs"
# The stub answers like gh with --jq applied: tab-separated rows from files.
cat >"$work/gh" <<'EOF'
#!/bin/sh
echo "gh $*" >>"$CALLS"
case "$*" in
  *"-X DELETE"*)
    [ -z "${GH_DELETE_FAIL:-}" ] || { echo "gh: HTTP 422" >&2; exit 1; }
    ;;
  *"-X POST"*)
    if [ -n "${GH_CREATE_ERR:-}" ]; then echo "$GH_CREATE_ERR" >&2; exit 1; fi
    echo '{"id": 7}'
    ;;
  *users/*) echo "${GH_OWNER_TYPE:-Organization}" ;;
  *runner-groups*)
    if [ -n "${GH_LIST_FAIL:-}" ]; then echo '{"message":"Must have admin rights"}'; echo "gh: HTTP 403" >&2; exit 1; fi
    cat "$GH_GROUPS"
    ;;
  *actions/runners*)
    if [ -n "${GH_RUNNERS_FAIL:-}" ]; then echo '{"message":"Not Found"}'; exit 1; fi
    cat "$GH_RUNNERS"
    ;;
esac
EOF
chmod +x "$work/gh"
for t in awk cat dirname git grep sh sleep tr; do ln -s "$(command -v "$t")" "$stubs/$t"; done
cp "$work/gh" "$stubs/gh"
# For the install ordering test: a Mac, and a Lima with no VM.
cat >"$stubs/uname" <<'EOF'
#!/bin/sh
case "$1" in -s) echo Darwin ;; -m) echo arm64 ;; esac
EOF
cat >"$stubs/limactl" <<'EOF'
#!/bin/sh
echo "limactl $*" >>"$CALLS"
case "$1" in
  --version) echo "limactl version 2.2.0" ;;
  list)
    # Every instance, as `list --format '{{.Name}} {{.Status}}'`: another VM, and
    # this one when LIMA_STATUS is set. LIMA_LIST_FAIL: Lima cannot answer.
    if [ -n "${LIMA_LIST_FAIL:-}" ]; then echo "limactl: list failed" >&2; exit 1; fi
    echo "other-vm Stopped"
    [ -z "${LIMA_STATUS:-}" ] || echo "homefield ${LIMA_STATUS}"
    ;;
  shell)
    case "$*" in
      *"test -e"*)
        # Can the guest see /Users? LIMA_USERS_FAIL: the call never reaches the guest.
        if [ -n "${LIMA_USERS_FAIL:-}" ]; then echo "limactl: could not connect" >&2; exit 1; fi
        if [ -n "${LIMA_SEES_USERS:-}" ]; then echo yes; else echo no; fi
        exit 0
        ;;
      *'$(mount)'*)
        # LIMA_RUN_GUEST: run the mount check itself here, against the mount stub.
        if [ -n "${LIMA_RUN_GUEST:-}" ]; then shift 4; exec "$@"; fi
        ;;
    esac
    case "$*" in
      *pgrep*)
        # Is a job running? LIMA_JOB_FAIL: the call never reaches the guest.
        if [ -n "${LIMA_JOB_FAIL:-}" ]; then echo "limactl: could not connect" >&2; exit 1; fi
        printf '%s\n' "${LIMA_JOB-no}"
        exit 0
        ;;
      *"test -f"*"/.runner"*)
        # Is the runner registered? LIMA_REG_FAIL: the call never reaches the guest.
        if [ -n "${LIMA_REG_FAIL:-}" ]; then echo "limactl: could not connect" >&2; exit 1; fi
        printf '%s\n' "${LIMA_REGISTERED-no}"
        exit 0
        ;;
    esac
    if [ -n "${LIMA_SHELL_FAIL:-}" ]; then echo "limactl: could not connect" >&2; exit 1; fi
    printf '%s' "${LIMA_SHELL_OUT:-}"
    ;;
esac
EOF
# This Mac's name for the default runner name; SCUTIL_FAIL makes it unreadable.
cat >"$stubs/scutil" <<'EOF'
#!/bin/sh
[ -z "${SCUTIL_FAIL:-}" ] || exit 1
echo "${SCUTIL_NAME:-Test-Mac}"
EOF
# What `mount` prints in the guest (MOUNT_OUT), or fails (MOUNT_FAIL).
cat >"$stubs/mount" <<'EOF'
#!/bin/sh
[ -z "${MOUNT_FAIL:-}" ] || { echo "mount: cannot read /proc/mounts" >&2; exit 1; }
printf '%s\n' "${MOUNT_OUT:-}"
EOF
chmod +x "$stubs/uname" "$stubs/limactl" "$stubs/scutil" "$stubs/mount"

printf 'Default\tall\tfalse\nhomefield-ci\tselected\tfalse\nLocal CI\tselected\tfalse\n' >"$work/groups-ok"
printf 'Default\tall\tfalse\nhomefield-ci\tall\tfalse\n' >"$work/groups-all"
printf 'Default\tall\tfalse\nhomefield-ci\tselected\ttrue\n' >"$work/groups-public"
printf 'Default\tall\tfalse\n' >"$work/groups-none"

# run_fn [VAR=value ...] -- <function> [args]: sets out and rc. No terminal.
run_fn() {
  local envs=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do
    envs+=("$1")
    shift
  done
  shift
  : >"$calls"
  # shellcheck disable=SC2016  # the -c script is expanded by the inner bash
  out="$(env -i HOME="$work" PATH="$stubs" CALLS="$calls" HOMEFIELD_SOURCE_ONLY=1 "${envs[@]+"${envs[@]}"}" \
    "$BASH" -c '. "$1"; shift; ONLINE_WAIT_INTERVAL=0; ONLINE_WAIT_TRIES=3; "$@"' _ "$ROOT/bin/homefield" "$@" 2>&1 </dev/null)"
  rc=$?
}
called() { grep -c -e "$1" "$calls" || true; }

# ── ensure_group ───────────────────────────────────────────────────────────
echo "ensure_group"
run_fn GH_GROUPS="$work/groups-ok" -- ensure_group https://github.com/acme homefield-ci
record "an existing selected group is accepted" "0/yes/no" "$rc/$(has "$out" 'runner group homefield-ci exists')/$(has "$out" warning)"
record "...with one list call and no create" "1/0" "$(called 'runner-groups')/$(called 'POST')"
record "the list is paginated" "1" "$(called '--paginate')"

run_fn GH_GROUPS="$work/groups-ok" -- ensure_group https://github.com/acme "Local CI"
record "a group name with a space is found" "0/yes/0" "$rc/$(has "$out" 'runner group Local CI exists')/$(called POST)"

run_fn GH_GROUPS="$work/groups-ok" -- ensure_group https://github.com/acme/ homefield-ci
record "a trailing slash on the URL is fine" "0/yes" "$rc/$(has "$out" 'exists')"

run_fn GH_GROUPS="$work/groups-all" -- ensure_group https://github.com/acme homefield-ci
record "visibility all: a warning, not an error" "0/yes/yes/0" "$rc/$(has "$out" 'warning: runner group homefield-ci is wider')/$(has "$out" 'every repository in acme')/$(called POST)"
record "...pointing at the runbook" "yes" "$(has "$out" 'Runner group')"

run_fn GH_GROUPS="$work/groups-public" -- ensure_group https://github.com/acme homefield-ci
record "public repositories allowed: a warning" "0/yes/yes" "$rc/$(has "$out" 'warning')/$(has "$out" 'public repositories can use it')"

run_fn GH_GROUPS="$work/groups-none" -- ensure_group https://github.com/acme homefield-ci
record "a missing group is created" "0/1/yes" "$rc/$(called POST)/$(has "$out" 'created runner group homefield-ci')"
record "...as selected repositories, public off, by name" \
  "gh api -X POST orgs/acme/actions/runner-groups -f name=homefield-ci -f visibility=selected -F allows_public_repositories=false" \
  "$(grep POST "$calls")"
record "...and says no repository can use it yet" "yes" "$(has "$out" 'docs/adopting.md, step 5')"

run_fn GH_GROUPS="$work/groups-none" -- ensure_group https://github.com/acme "Local CI"
record "a name with a space is passed as one argument" "name=Local CI" "$(grep -o 'name=Local CI' "$calls" | head -1)"

run_fn GH_GROUPS="$work/groups-none" "GH_CREATE_ERR=gh: Upgrade to GitHub Team or Enterprise to use runner groups. (HTTP 403)" -- ensure_group https://github.com/acme homefield-ci
record "creation refused by the plan: an error" "nonzero" "$(nonzero "$rc")"
record "...that says custom groups need Team or Enterprise" "yes" "$(has "$out" 'need the GitHub Team plan or Enterprise')"
record "...offers --group Default and what it means" "yes/yes" "$(has "$out" '--group Default')/$(has "$out" 'every repository in acme can then use the runner')"
record "...offers a repository URL" "yes" "$(has "$out" 'https://github.com/<owner>/<repo>')"
record "...and shows what gh said" "yes" "$(has "$out" 'Upgrade to GitHub Team or Enterprise to use runner groups')"

# A bare 403 or 422 is not taken for the plan: the plan advice opens the
# runner to every repository, so it needs the plan's own wording.
run_fn GH_GROUPS="$work/groups-none" "GH_CREATE_ERR=gh: Validation Failed (HTTP 422)" -- ensure_group https://github.com/acme homefield-ci
record "a bare 422 is not read as the plan" "nonzero/no/yes" "$(nonzero "$rc")/$(has "$out" '--group Default')/$(has "$out" 'Validation Failed')"

run_fn GH_GROUPS="$work/groups-none" "GH_CREATE_ERR=Resource protected by organization SAML enforcement. You must grant your Personal Access token access to this organization. (HTTP 403)" -- ensure_group https://github.com/acme homefield-ci
record "SAML enforcement is named, without the plan advice" "nonzero/yes/no" "$(nonzero "$rc")/$(has "$out" 'SAML single sign-on')/$(has "$out" '--group Default')"

run_fn GH_GROUPS="$work/groups-none" "GH_CREATE_ERR=gh: Server Error (HTTP 500)" -- ensure_group https://github.com/acme homefield-ci
record "any other creation error is not called a plan problem" "nonzero/no/yes" "$(nonzero "$rc")/$(has "$out" '--group Default')/$(has "$out" 'Server Error')"
record "...and, without a terminal to ask, stops" "yes" "$(has "$out" 'no terminal to ask')"

# GitHub compares group names case-insensitively.
printf 'Default\tall\tfalse\nHomeField-CI\tselected\tfalse\n' >"$work/groups-case"
run_fn GH_GROUPS="$work/groups-case" -- ensure_group https://github.com/acme homefield-ci
record "a group that differs only in case is found, not created again" "0/yes/0" "$rc/$(has "$out" 'runner group HomeField-CI exists')/$(called POST)"
run_fn GH_GROUPS="$work/groups-ok" -- ensure_group https://github.com/acme default
record "--group default (any case) is the Default group: skipped" "0/0" "$rc/$(called 'runner-groups')"

# GROUP_STATE drives install's closing message.
# shellcheck disable=SC2016  # expanded by the inner bash
state_of() { run_fn "$@" -- eval 'ensure_group "$URL" "$GROUP"; echo "state=$GROUP_STATE"'; echo "$out" | sed -n 's/^state=//p'; }
record "state: an existing narrow group" "narrow" "$(state_of GH_GROUPS="$work/groups-ok" URL=https://github.com/acme GROUP=homefield-ci)"
record "state: a group open to every repository" "wide" "$(state_of GH_GROUPS="$work/groups-all" URL=https://github.com/acme GROUP=homefield-ci)"
record "state: created" "created" "$(state_of GH_GROUPS="$work/groups-none" URL=https://github.com/acme GROUP=homefield-ci)"
record "state: Default" "default" "$(state_of GH_GROUPS="$work/groups-ok" URL=https://github.com/acme GROUP=Default)"
record "state: a repository URL" "repo" "$(state_of GH_GROUPS="$work/groups-ok" URL=https://github.com/acme/app GROUP=homefield-ci)"

# A successful list proves admin:org, so the token step must not offer a
# scope refresh afterwards.
# shellcheck disable=SC2016  # expanded by the inner bash
run_fn GH_GROUPS="$work/groups-ok" -- eval 'ensure_group https://github.com/acme homefield-ci; echo "asked=$scope_refresh_asked"'
record "after a successful list, the scope refresh is not offered again" "asked=1" "$(echo "$out" | grep '^asked=' || true)"

run_fn GH_GROUPS="$work/groups-none" -- ensure_group https://github.com/acme Default
record "Default is skipped: no gh call at all" "0/0" "$rc/$(wc -l <"$calls" | tr -d ' ')"

run_fn GH_GROUPS="$work/groups-none" -- ensure_group https://github.com/acme/app homefield-ci
record "a repository URL has no group: no gh call" "0/0" "$rc/$(wc -l <"$calls" | tr -d ' ')"

run_fn GH_LIST_FAIL=1 -- ensure_group https://github.com/acme homefield-ci
record "when gh cannot list the groups and there is no terminal: stops" "nonzero/yes/yes" "$(nonzero "$rc")/$(has "$out" 'could not check or create the runner group homefield-ci')/$(has "$out" 'no terminal to ask')"
record "...says where the manual steps are, and never creates" "yes/0" "$(has "$out" 'Runner group')/$(called POST)"
record "...and names --group-exists" "yes" "$(has "$out" 'pass --group-exists')"
run_fn GH_LIST_FAIL=1 GITHUB_TOKEN=x -- ensure_group https://github.com/acme homefield-ci
record "...with GITHUB_TOKEN set, says to run again with it empty" "nonzero/yes" "$(nonzero "$rc")/$(has "$out" 'GITHUB_TOKEN= GH_TOKEN= homefield install')"
run_fn GH_LIST_FAIL=1 -- ensure_group https://github.com/acme homefield-ci
record "...and without it, does not" "no" "$(has "$out" 'GITHUB_TOKEN=')"

# --group-exists: the caller vouches for a group gh cannot look at.
# shellcheck disable=SC2016  # expanded by the inner bash
run_fn GH_LIST_FAIL=1 -- eval 'GROUP_EXISTS=1; ensure_group https://github.com/acme homefield-ci; echo "state=$GROUP_STATE"'
record "--group-exists, gh cannot list: goes on, still unchecked, never creates" "0/yes/state=unchecked/no/0" \
  "$rc/$(has "$out" 'going on because of --group-exists')/$(echo "$out" | grep '^state=')/$(has "$out" 'no terminal to ask')/$(called POST)"
mv "$stubs/gh" "$work/gh.away"
# shellcheck disable=SC2016  # expanded by the inner bash
run_fn -- eval 'GROUP_EXISTS=1; ensure_group https://github.com/acme homefield-ci'
record "--group-exists without gh: goes on" "0/yes" "$rc/$(has "$out" 'going on because of --group-exists')"
mv "$work/gh.away" "$stubs/gh"
# shellcheck disable=SC2016  # expanded by the inner bash
run_fn GH_GROUPS="$work/groups-none" -- eval 'GROUP_EXISTS=1; ensure_group https://github.com/acme homefield-ci; echo "state=$GROUP_STATE"'
record "--group-exists, but the list works and lacks it: warned, and created as usual" "0/yes/state=created" \
  "$rc/$(has "$out" 'is not among them')/$(echo "$out" | grep '^state=')"
# shellcheck disable=SC2016  # expanded by the inner bash
run_fn GH_GROUPS="$work/groups-none" "GH_CREATE_ERR=gh: Server Error (HTTP 500)" -- eval 'GROUP_EXISTS=1; ensure_group https://github.com/acme homefield-ci'
record "...and when that creation fails, it still stops" "nonzero/yes" "$(nonzero "$rc")/$(has "$out" 'no terminal to ask')"

# No gh at all.
mv "$stubs/gh" "$work/gh.away"
run_fn -- ensure_group https://github.com/acme homefield-ci
record "without gh: stops, saying so" "nonzero/yes" "$(nonzero "$rc")/$(has "$out" 'gh is not installed')"
mv "$work/gh.away" "$stubs/gh"

# ── install: what is checked before a VM is created ────────────────────────
echo "install ordering"
run_fn -- cmd_install
record "no VM, no URL, no terminal: stops before creating anything" "nonzero/yes/0" "$(nonzero "$rc")/$(has "$out" '--url is required')/$(called 'limactl create')"

run_fn GH_GROUPS="$work/groups-none" "GH_CREATE_ERR=gh: Upgrade to GitHub Team (HTTP 403)" -- cmd_install --url https://github.com/acme
record "no VM, Free plan: the group error comes before the VM is created" "nonzero/yes/0" "$(nonzero "$rc")/$(has "$out" '--group Default')/$(called 'limactl create')"

run_fn GH_OWNER_TYPE=User -- cmd_install --url https://github.com/someone
record "no VM, a personal account: refused before the VM is created" "nonzero/yes/0" "$(nonzero "$rc")/$(has "$out" 'personal account')/$(called 'limactl create')"

run_fn GH_GROUPS="$work/groups-none" "GH_CREATE_ERR=gh: Upgrade to GitHub Team (HTTP 403)" -- cmd_install --url https://github.com/acme --group Default
record "--group Default skips the group step" "nonzero/no" "$(nonzero "$rc")/$(has "$out" 'Team')"

run_fn GH_LIST_FAIL=1 -- cmd_install --url https://github.com/acme --group-exists
record "install --group-exists: past the group step to creating the VM" "yes/no/yes" \
  "$(has "$out" 'going on because of --group-exists')/$(has "$out" 'no terminal to ask')/$([ "$(called 'limactl create')" -gt 0 ] && echo yes || echo no)"

run_fn LIMA_STATUS=Running -- cmd_install --url not-a-url
record "a bad URL is refused before an existing VM is touched" "nonzero/yes/0" "$(nonzero "$rc")/$(has "$out" '--url must be')/$(called 'limactl start')"

printf 'test-mac-homefield\tonline\t41\n' >"$work/runners-name-online"
run_fn GH_GROUPS="$work/groups-ok" GH_RUNNERS="$work/runners-name-online" -- cmd_install --url https://github.com/acme
record "no VM, the default name taken: refused before the VM is created" "nonzero/yes/0" "$(nonzero "$rc")/$(has "$out" 'test-mac-homefield is already registered and online')/$(called 'limactl create')"

# A failed probe of the guest is not an answer (#80): with a VM that is already
# there, install asks whether it is registered, and "no" starts a fresh
# registration, where --replace deletes this VM's own runner from GitHub.
run_fn LIMA_STATUS=Running LIMA_SHELL_OUT=0 LIMA_REG_FAIL=1 GH_GROUPS="$work/groups-ok" GH_RUNNERS="$work/runners-name-online" \
  -- cmd_install --url https://github.com/acme --replace
record "the registered probe fails: install stops before any change" "nonzero/yes/0/0" \
  "$(nonzero "$rc")/$(has "$out" 'could not ask VM')/$(called 'DELETE')/$(called 'POST')"
for answer in "yes:0" "no:1" "maybe:2" ":2"; do
  run_fn LIMA_REGISTERED="${answer%%:*}" -- registered
  record "registered: the guest says '${answer%%:*}'" "${answer##*:}" "$rc"
done
run_fn LIMA_REG_FAIL=1 -- registered
record "registered: the call fails" "2" "$rc"

# The same for upgrade's idle check (#82): a call that failed is not "idle", with
# --force too.
for args in "" "--force"; do
  run_fn LIMA_STATUS=Running LIMA_SHELL_OUT=0 LIMA_REGISTERED=yes LIMA_JOB_FAIL=1 -- cmd_upgrade $args
  record "upgrade $args: the job probe fails: stops, nothing stopped or provisioned" "nonzero/yes/0/0" \
    "$(nonzero "$rc")/$(has "$out" 'whether a job is running')/$(called 'systemctl')/$(called 'provision')"
done
run_fn LIMA_STATUS=Running LIMA_SHELL_OUT=0 LIMA_REGISTERED=yes LIMA_JOB=yes -- cmd_upgrade
record "upgrade: a job is running: refused, pointing at --force" "nonzero/yes/0" \
  "$(nonzero "$rc")/$(has "$out" 'a job is running on')/$(called 'systemctl')"
for answer in "yes:0" "no:1" "maybe:2" ":2"; do
  run_fn LIMA_JOB="${answer%%:*}" -- job_running
  record "job_running: the guest says '${answer%%:*}'" "${answer##*:}" "$rc"
done
run_fn LIMA_JOB_FAIL=1 -- job_running
record "job_running: the call fails" "2" "$rc"

# ── runner name ────────────────────────────────────────────────────────────
echo "runner name"
run_fn -- default_name
record "default: this Mac's local hostname and the instance, lower case" "0/test-mac-homefield" "$rc/$out"
run_fn SCUTIL_NAME=Studio-2 HOMEFIELD_INSTANCE=CI.b -- default_name
record "...with another instance" "studio-2-ci.b" "$out"
run_fn "SCUTIL_NAME=Ana's Mac" -- default_name
record "...characters a runner name should not have become '-'" "ana-s-mac-homefield" "$out"
run_fn SCUTIL_FAIL=1 -- default_name
record "an unreadable Mac name stops, asking for --name" "nonzero/yes" "$(nonzero "$rc")/$(has "$out" 'pass --name')"

# Rows as check_name_free's --jq makes them: name, status, id.
printf 'other\tonline\t41\nlima-homefield\toffline\t42\n' >"$work/runners-names"
run_fn GH_RUNNERS="$work/runners-names" -- check_name_free https://github.com/acme test-mac-homefield 0
record "a free name passes, reading the runners list paginated" "0/1" "$rc/$(called 'paginate orgs/acme/actions/runners')"
run_fn GH_RUNNERS="$work/runners-names" -- check_name_free https://github.com/acme OTHER 0
record "a name online elsewhere is refused, ignoring case" "nonzero/yes/yes" "$(nonzero "$rc")/$(has "$out" 'OTHER is already registered and online')/$(has "$out" '--name')"
run_fn GH_RUNNERS="$work/runners-names" -- check_name_free https://github.com/acme lima-homefield 0
record "an offline one is refused, offering --replace and the runners page" "nonzero/yes/yes" "$(nonzero "$rc")/$(has "$out" 'run this again with --replace')/$(has "$out" 'organizations/acme/settings/actions/runners')"
# shellcheck disable=SC2016  # $REPLACE_ID is expanded by the sourced shell
run_fn GH_RUNNERS="$work/runners-names" -- eval 'check_name_free https://github.com/acme lima-homefield 1 && echo "id=$REPLACE_ID"'
record "--replace: an offline one is marked for removal, by id" "0/yes/yes" "$rc/$(has "$out" '--replace removes that registration before registering')/$(has "$out" 'id=42')"
# shellcheck disable=SC2016  # $REPLACE_ID is expanded by the sourced shell
run_fn GH_RUNNERS="$work/runners-names" -- eval 'check_name_free https://github.com/acme other 1 && echo "id=$REPLACE_ID"'
record "--replace: an online one too, with a warning" "0/yes/yes" "$rc/$(has "$out" 'warning: other is registered and online')/$(has "$out" 'id=41')"
# shellcheck disable=SC2016  # $REPLACE_ID is expanded by the sourced shell
run_fn GH_RUNNERS="$work/runners-names" -- eval 'check_name_free https://github.com/acme free-name 1 && echo "id=[$REPLACE_ID]"'
record "--replace with a free name removes nothing" "0/yes" "$rc/$(has "$out" 'id=[]')"
run_fn GH_RUNNERS_FAIL=1 -- check_name_free https://github.com/acme other 1
record "--replace with an unreadable list stops, pointing at the runners page" "nonzero/yes" "$(nonzero "$rc")/$(has "$out" 'remove other at https://github.com/organizations/acme/settings/actions/runners')"

run_fn -- eval 'REPLACE_ID=42; remove_taken_name https://github.com/acme lima-homefield'
record "remove_taken_name deletes the runner by id" "0/gh api -X DELETE orgs/acme/actions/runners/42" "$rc/$(grep DELETE "$calls")"
run_fn -- remove_taken_name https://github.com/acme lima-homefield
record "...and nothing without an id" "0/0" "$rc/$(called DELETE)"
run_fn GH_DELETE_FAIL=1 -- eval 'REPLACE_ID=42; remove_taken_name https://github.com/acme/app lima-homefield'
record "...a failed delete stops the install, pointing at the runners page" "nonzero/yes" "$(nonzero "$rc")/$(has "$out" 'remove it at https://github.com/acme/app/settings/actions/runners')"
run_fn GH_RUNNERS="$work/runners-names" -- check_name_free https://github.com/acme/app other 0
record "a repository scope reads the repository's runners" "nonzero/1" "$(nonzero "$rc")/$(called 'repos/acme/app/actions/runners')"
run_fn GH_RUNNERS_FAIL=1 -- check_name_free https://github.com/acme other 0
record "an unreadable list does not stop the install" "0/yes" "$rc/$(has "$out" 'registration refuses it if it is not')"

# config.sh --replace takes another runner's registration (#52) and keeps its
# runner group (actions/runner#4091), so provision.sh must never pass it.
record "provision.sh never registers with --replace" "0" "$(grep -c -e '^[^#]*--replace' "$ROOT/vm/provision.sh")"

# ── wait_online ────────────────────────────────────────────────────────────
echo "wait_online"
printf 'other\tonline\tself-hosted\tDefault\nlima-homefield\toffline\tself-hosted,Linux\thomefield-ci\n' >"$work/runners-offline"
printf 'lima-homefield\tonline\tself-hosted,Linux,ARM64,homefield-ci\t7\n' >"$work/runners-online"
printf 'lima-homefield\tonline\tself-hosted,Linux,ARM64,homefield-ci\t\n' >"$work/runners-nogroup"
# The runner-groups list as [id, name] rows; wait_online resolves the id to a name.
printf '7\thomefield-ci\n' >"$work/groups-ids"
printf '7\tDefault\n' >"$work/groups-ids-other"

run_fn GH_RUNNERS="$work/runners-online" GH_GROUPS="$work/groups-ids" -- wait_online https://github.com/acme lima-homefield homefield-ci
record "online: reports labels and the resolved group" "0/yes" "$rc/$(has "$out" 'lima-homefield is online: labels self-hosted,Linux,ARM64,homefield-ci, group homefield-ci')"
record "...from the organization's runners and groups, paginated" "1/2" "$(called 'orgs/acme/actions/runners')/$(called '--paginate')"

run_fn GH_RUNNERS="$work/runners-online" GH_GROUPS="$work/groups-ids-other" -- wait_online https://github.com/acme lima-homefield homefield-ci
record "the runner registered into another group: observed, with the expected one" \
  "0/yes/no" "$rc/$(has "$out" 'group Default (expected homefield-ci)')/$(has "$out" 'group homefield-ci')"

run_fn GH_RUNNERS="$work/runners-online" GH_LIST_FAIL=1 -- wait_online https://github.com/acme lima-homefield homefield-ci
record "the groups list cannot be read: the observed id, not the expected name" \
  "0/yes/no" "$rc/$(has "$out" 'group id 7')/$(has "$out" 'group homefield-ci')"

run_fn GH_RUNNERS="$work/runners-nogroup" GH_GROUPS="$work/groups-ids" -- wait_online https://github.com/acme lima-homefield homefield-ci
record "no group id from GitHub: only the labels are claimed" \
  "0/yes/no" "$rc/$(has "$out" 'is online: labels self-hosted,Linux,ARM64,homefield-ci')/$(has "$out" 'group')"

run_fn GH_RUNNERS="$work/runners-online" -- wait_online https://github.com/acme/app lima-homefield homefield-ci
record "a repository runner: read from the repository, no group" "0/1/no" "$rc/$(called 'repos/acme/app/actions/runners')/$(has "$out" 'group')"

run_fn GH_RUNNERS="$work/runners-offline" -- wait_online https://github.com/acme lima-homefield homefield-ci
record "never online: a warning with the runners page, and the install does not fail" \
  "0/yes/yes/yes" "$rc/$(has "$out" 'warning: lima-homefield is not online')/$(has "$out" 'https://github.com/organizations/acme/settings/actions/runners')/$(has "$out" 'offline')"
record "...after polling the set number of times" "3" "$(called 'actions/runners')"

run_fn GH_RUNNERS_FAIL=1 -- wait_online https://github.com/acme lima-homefield homefield-ci
record "gh cannot read the list: the page to check by hand, no failure" "0/yes/1" "$rc/$(has "$out" 'https://github.com/organizations/acme/settings/actions/runners')/$(called 'actions/runners')"

run_fn GH_RUNNERS="$work/runners-online" -- wait_online https://github.com/acme "" homefield-ci
record "no runner name: the page to check by hand" "0/yes/0" "$rc/$(has "$out" 'check that the runner is online at')/$(called 'actions/runners')"

# ── verify_isolation ───────────────────────────────────────────────────────
echo "verify_isolation"
run_fn LIMA_SHELL_OUT=0 -- verify_isolation
record "no host mounts: verified" "0/yes" "$rc/$(has "$out" 'isolation verified: no host mounts')"

run_fn LIMA_SHELL_OUT=2 -- verify_isolation
record "host mounts: refused" \
  "nonzero/yes/no" "$(nonzero "$rc")/$(has "$out" 'has host mounts')/$(has "$out" 'isolation verified')"

run_fn LIMA_SHELL_OUT=0 LIMA_SEES_USERS=1 -- verify_isolation
record "the guest can see /Users: refused" "nonzero/yes" "$(nonzero "$rc")/$(has "$out" 'can see /Users')"

run_fn LIMA_SHELL_FAIL=1 -- verify_isolation
record "the check cannot run: refused, not read as host mounts" \
  "nonzero/yes/no" "$(nonzero "$rc")/$(has "$out" 'could not run the isolation check')/$(has "$out" 'has host mounts')"

run_fn LIMA_SHELL_OUT=nonsense -- verify_isolation
record "an unreadable mount count: refused" "nonzero/yes" "$(nonzero "$rc")/$(has "$out" 'could not read the mount count')"

# The probes of #85, with the mount check run for real against a stub mount.
run_fn LIMA_RUN_GUEST=1 MOUNT_OUT='proc on /proc type proc (rw)' -- verify_isolation
record "mount lists no host mounts: verified (grep -c exits 1 for a count of 0)" "0/yes" "$rc/$(has "$out" 'isolation verified: no host mounts')"
run_fn LIMA_RUN_GUEST=1 MOUNT_OUT='mount0 on /Users type virtiofs (rw)' -- verify_isolation
record "mount lists a virtiofs mount: refused" "nonzero/yes/no" "$(nonzero "$rc")/$(has "$out" 'has host mounts')/$(has "$out" 'isolation verified')"
run_fn LIMA_RUN_GUEST=1 MOUNT_FAIL=1 -- verify_isolation
record "mount itself fails: refused as unable to run, not counted as 0" "nonzero/yes/no" "$(nonzero "$rc")/$(has "$out" 'could not run the isolation check')/$(has "$out" 'isolation verified')"
run_fn LIMA_SHELL_OUT=0 LIMA_USERS_FAIL=1 -- verify_isolation
record "the /Users call fails: refused, not read as 'cannot see it'" "nonzero/yes/no" "$(nonzero "$rc")/$(has "$out" 'could not run the /Users check')/$(has "$out" 'isolation verified')"

# ── vm_status: Lima that cannot answer is not "no VM" (#85) ──────────────────
echo "vm_status"
run_fn LIMA_STATUS=Running -- vm_status
record "an existing VM: its status" "0/Running" "$rc/$out"
run_fn LIMA_STATUS= -- vm_status
record "no VM among the listed ones: nothing, and success" "0/" "$rc/$out"
run_fn LIMA_LIST_FAIL=1 -- vm_status
record "limactl list fails: status 2, nothing printed" "2/" "$rc/$out"
run_fn LIMA_LIST_FAIL=1 GH_GROUPS="$work/groups-none" -- cmd_install --url https://github.com/acme
record "install: Lima cannot answer: stops before a group or a VM is created" "nonzero/yes/0/0" \
  "$(nonzero "$rc")/$(has "$out" 'could not ask Lima about VM')/$(called 'POST')/$(called 'limactl create')"
for command in cmd_upgrade cmd_uninstall "cmd_memory --days 1"; do
  # shellcheck disable=SC2086  # the command and its option are words
  run_fn LIMA_LIST_FAIL=1 -- $command
  record "${command%% *}: Lima cannot answer: says so, not that there is no VM" "nonzero/yes/no" \
    "$(nonzero "$rc")/$(has "$out" 'could not ask Lima about VM')/$(has "$out" 'no VM')"
done
run_fn LIMA_LIST_FAIL=1 -- cmd_status
record "status: Lima cannot answer: unknown, not 'not created', exit 1" "1/yes/no" "$rc/$(has "$out" 'VM homefield: unknown')/$(has "$out" 'not created')"
run_fn -- cmd_status
record "status: no VM: not created, exit 0" "0/yes" "$rc/$(has "$out" 'VM homefield: not created')"

# ── version ────────────────────────────────────────────────────────────────
echo "version"
mkdir -p "$work/inst/bin" "$work/bare/bin" "$work/nogh"
cp "$ROOT/bin/homefield" "$work/inst/bin/homefield"
cp "$ROOT/bin/homefield" "$work/bare/bin/homefield"
for t in dirname git; do ln -s "$(command -v "$t")" "$work/nogh/$t"; done
old=0123456789abcdef0123456789abcdef01234567
new=89abcdef0123456789abcdef0123456789abcdef
printf 'repo=acme/tool\nref=v0.1.0\ncommit=%s\n' "$old" >"$work/inst/.homefield-ref"
# Without gh, so only the first line, which is not about updates.
out="$(env -i PATH="$work/nogh" "$BASH" "$work/inst/bin/homefield" version 2>&1)"
record "an install.sh copy reports its ref, short commit and source" "homefield v0.1.0 (0123456), installed from acme/tool in $work/inst" "${out%%$'\n'*}"
out="$(env -i PATH="$stubs" GIT_CEILING_DIRECTORIES="$work" "$BASH" "$work/bare/bin/homefield" version 2>&1)"
record "neither a ref file nor a checkout" "homefield (version unknown), in $work/bare" "$out"
: >"$calls"
out="$(env -i PATH="$stubs" CALLS="$calls" "$BASH" "$ROOT/bin/homefield" version 2>&1)"
record "a checkout says so, and asks gh nothing" "yes/0" "$(has "$out" 'from a checkout in')/$(called 'gh api')"

# A gh that answers the two update-check calls: the commit a ref resolves to
# (the commits endpoint follows an annotated tag to its commit) and the tags.
mkdir -p "$work/vgh"
for t in dirname git; do ln -s "$(command -v "$t")" "$work/vgh/$t"; done
cat >"$work/vgh/gh" <<'EOF'
#!/bin/sh
echo "gh $*" >>"$CALLS"
if [ -n "${V_GH_FAIL:-}" ]; then echo '{"message":"Bad credentials"}'; echo "gh: HTTP 401" >&2; exit 1; fi
case "$*" in
  *repos/*/commits/*) echo "$V_COMMIT" ;;
  *repos/*/tags*) printf '%s\n' "$V_TAGS" ;;
esac
EOF
chmod +x "$work/vgh/gh"
# Tags that are not a plain release (v1, v0.1, latest) are ignored.
tags_rel="$(printf 'v0.1.0\nv1\nv0.1\nv0.0.9\nlatest')"
# version_run [VAR=value ...]: out and rc of `version` on the install.sh copy.
version_run() {
  : >"$calls"
  out="$(env -i HOME="$work" PATH="$work/vgh" CALLS="$calls" V_TAGS="$tags_rel" "$@" "$BASH" "$work/inst/bin/homefield" version 2>&1 </dev/null)"
  rc=$?
}
mine="homefield v0.1.0 (0123456), installed from acme/tool in $work/inst"

version_run V_COMMIT="$old"
record "unchanged ref: up to date" "0/$mine
homefield: up to date with v0.1.0" "$rc/$out"
record "...resolved through the commits endpoint, tags listed" "1/1" "$(called 'repos/acme/tool/commits/v0.1.0')/$(called 'repos/acme/tool/tags')"

printf 'repo=acme/tool\nref=v0.1.0\ncommit=0123456\n' >"$work/inst/.homefield-ref"
version_run V_COMMIT="$old"
record "a short recorded commit still matches" "0/homefield: up to date with v0.1.0" "$rc/$(printf '%s' "$out" | tail -1)"
printf 'repo=acme/tool\nref=v0.1.0\ncommit=%s\n' "$old" >"$work/inst/.homefield-ref"

version_run V_COMMIT="$new"
record "a moved ref: says where it moved, exit 0" "0/yes" "$rc/$(has "$out" 'homefield: v0.1.0 has moved to 89abcde since this copy was installed; update with:')"
record "...with the one-liner for that ref and this copy" "yes" "$(has "$out" "  curl -fsSL https://raw.githubusercontent.com/acme/tool/v0.1.0/install.sh | HOMEFIELD_REPO=acme/tool HOMEFIELD_REF=v0.1.0 HOMEFIELD_HOME='$work/inst' bash")"
record "...saying the VM is left alone" "yes" "$(has "$out" 'homefield upgrade updates the VM')"
record "...and no later release when v0.1.0 is the highest" "no" "$(has "$out" ' is out ')"
record "...the VM note comes once" "1" "$(printf '%s\n' "$out" | grep -c 'homefield upgrade updates the VM')"

# The README's one-liner exactly: default repository and ref, in the default place.
dflt="$work/h/.local/share/homefield"
mkdir -p "$dflt/bin"
cp "$ROOT/bin/homefield" "$dflt/bin/homefield"
printf 'repo=i2Dev-com/homefield\nref=v0.2.1\ncommit=%s\n' "$old" >"$dflt/.homefield-ref"
: >"$calls"
out="$(env -i HOME="$work/h" PATH="$work/vgh" CALLS="$calls" V_TAGS="$tags_rel" V_COMMIT="$new" "$BASH" "$dflt/bin/homefield" version 2>&1 </dev/null)"
record "default repo, ref and place: the README's one-liner" "yes" "$(has "$out" "
  curl -fsSL https://raw.githubusercontent.com/i2Dev-com/homefield/v0.2.1/install.sh | bash
")"

printf 'repo=acme/tool\nref=release/1\ncommit=%s\n' "$old" >"$work/inst/.homefield-ref"
version_run V_COMMIT="$new"
record "a branch: HOMEFIELD_REF in the one-liner, no release check" "yes/no" "$(has "$out" "HOMEFIELD_REPO=acme/tool HOMEFIELD_REF=release/1 HOMEFIELD_HOME=")/$(has "$out" ' is out ')"
version_run V_COMMIT="$new" V_TAGS="$(printf 'v0.1.0\nv0.3.0')"
record "...even when a release exists" "no" "$(has "$out" ' is out ')"

printf 'repo=acme/tool\nref=v0.1.0\ncommit=%s\n' "$old" >"$work/inst/.homefield-ref"
version_run V_COMMIT="$old" V_TAGS="$(printf 'v0.1.0\nv0.3.0')"
record "a later release: says so with the changelog and the one-liner for it, exit 0" "0/yes/yes/yes" "$rc/$(has "$out" 'homefield: v0.3.0 is out (installed: v0.1.0); read CHANGELOG.md for breaking changes, then update with:')/$(has "$out" "  curl -fsSL https://raw.githubusercontent.com/acme/tool/v0.3.0/install.sh | HOMEFIELD_REPO=acme/tool HOMEFIELD_REF=v0.3.0 HOMEFIELD_HOME='$work/inst' bash")/$(has "$out" 'up to date with v0.1.0')"
record "...saying the VM is left alone, once" "1" "$(printf '%s\n' "$out" | grep -c 'homefield upgrade updates the VM')"
version_run V_COMMIT="$old" V_TAGS="$(printf 'v0.3.0\nv0.1.0')"
record "...whatever the order of the tags" "yes" "$(has "$out" 'v0.3.0 is out')"
version_run V_COMMIT="$old" V_TAGS="$(printf 'v0.1.0\nv0.2.1')"
record "a later patch counts" "yes" "$(has "$out" 'v0.2.1 is out (installed: v0.1.0)')"
version_run V_COMMIT="$old" V_TAGS="$(printf 'v0.9.9\nv0.10.0\nv0.3.0\nv0.1.0\nv1\nv2.0')"
record "the highest release is compared as numbers, not text, and v1 is not a release" "yes/no" "$(has "$out" 'v0.10.0 is out')/$(has "$out" 'v2.0 is out')"
version_run V_COMMIT="$new" V_TAGS="$(printf 'v0.1.0\nv0.3.0')"
record "...and with a moved ref, both are said" "0/yes/yes/1" "$rc/$(has "$out" 'has moved')/$(has "$out" 'v0.3.0 is out')/$(printf '%s\n' "$out" | grep -c 'homefield upgrade updates the VM')"
printf 'repo=acme/tool\nref=v0.3.0\ncommit=%s\n' "$old" >"$work/inst/.homefield-ref"
version_run V_COMMIT="$old" V_TAGS="$(printf 'v0.1.0\nv0.3.0')"
record "installed at the highest release: nothing newer is said" "no" "$(has "$out" ' is out ')"
version_run V_COMMIT="$old" V_TAGS="$(printf 'v0.1.0')"
record "installed above every listed tag: nothing newer is said" "no" "$(has "$out" ' is out ')"
printf 'repo=acme/tool\nref=v0.1.0\ncommit=%s\n' "$old" >"$work/inst/.homefield-ref"
version_run V_COMMIT="$old" V_TAGS="latest"
record "no release tag listed: nothing newer is said" "no" "$(has "$out" ' is out ')"

printf 'repo=acme/tool\nref=%s\ncommit=%s\n' "$old" "$old" >"$work/inst/.homefield-ref"
version_run V_COMMIT="$new"
record "a full commit as the ref: nothing to compare, no commit lookup" "0/yes/0" "$rc/$(has "$out" 'installed at a fixed commit (0123456)')/$(called 'commits/')"
printf 'repo=acme/tool\nref=v0.1.0\ncommit=%s\n' "$old" >"$work/inst/.homefield-ref"

out="$(env -i HOME="$work" PATH="$work/nogh" "$BASH" "$work/inst/bin/homefield" version 2>&1 </dev/null)"
rc=$?
record "neither gh nor curl: one line, exit 0" "0/homefield: could not check for updates (neither gh nor curl is installed)" "$rc/$(printf '%s' "$out" | tail -1)"

# No gh, but curl: the public API, without a login. The fake answers like
# GitHub: the bare sha for the commits endpoint (Accept: ...sha), and
# pretty-printed JSON for the tags.
mkdir -p "$work/vcurl"
for t in dirname git sed; do ln -s "$(command -v "$t")" "$work/vcurl/$t"; done
cat >"$work/vcurl/curl" <<'EOF'
#!/bin/sh
echo "curl $*" >>"$CALLS"
if [ -n "${V_CURL_FAIL:-}" ]; then echo "curl: (22) The requested URL returned error: 404" >&2; exit 22; fi
case "$*" in
  *api.github.com/repos/*/commits/*) printf '%s' "$V_COMMIT" ;;
  *api.github.com/repos/*/tags*)
    echo '['
    printf '%s\n' "$V_TAGS" | while IFS= read -r t; do
      printf '  {\n    "name": "%s",\n    "commit": {\n      "sha": "%s"\n    }\n  },\n' "$t" "$V_COMMIT"
    done
    echo ']'
    ;;
esac
EOF
chmod +x "$work/vcurl/curl"
curl_run() {
  : >"$calls"
  out="$(env -i HOME="$work" PATH="$work/vcurl" CALLS="$calls" V_TAGS="$tags_rel" "$@" "$BASH" "$work/inst/bin/homefield" version 2>&1 </dev/null)"
  rc=$?
}
curl_run V_COMMIT="$old"
record "no gh, curl: up to date, through the public API" "0/homefield: up to date with v0.1.0/1" "$rc/$(printf '%s' "$out" | tail -1)/$(called 'api.github.com/repos/acme/tool/commits/v0.1.0')"
curl_run V_COMMIT="$old" V_TAGS="$(printf 'v0.1.0\nv0.3.0')"
record "...a later release from the tags JSON, with the one-liner" "yes/yes" "$(has "$out" 'homefield: v0.3.0 is out (installed: v0.1.0)')/$(has "$out" "curl -fsSL https://raw.githubusercontent.com/acme/tool/v0.3.0/install.sh")"
curl_run V_COMMIT="$new"
record "...a moved ref" "yes" "$(has "$out" 'homefield: v0.1.0 has moved to 89abcde')"
curl_run V_CURL_FAIL=1 V_COMMIT="$old"
record "...curl failing: one line naming it, exit 0, none of curl's output" "0/yes/no" "$rc/$(has "$out" 'homefield: could not check for updates (curl could not read v0.1.0 in acme/tool; a private repository needs gh)')/$(has "$out" 'returned error')"
version_run V_COMMIT="$old"
record "with gh there, gh is used and not curl" "0/0" "$rc/$(called 'curl ')"
record "...curl follows redirects (a renamed repository answers 301)" "2" "$(curl_run V_COMMIT="$old"; grep -c -- '-fsSL ' "$calls")"
printf 'repo=acme/tool\nref=release/1\ncommit=%s\n' "$old" >"$work/inst/.homefield-ref"
curl_run V_COMMIT="$old"
record "a branch with a slash: encoded in the path, for curl" "1/0/yes" "$(called 'repos/acme/tool/commits/release%2F1')/$(called 'commits/release/1')/$(has "$out" 'up to date with release/1')"
version_run V_COMMIT="$old"
record "...and for gh" "1/0" "$(called 'repos/acme/tool/commits/release%2F1')/$(called 'commits/release/1')"
printf 'repo=acme/tool\nref=v0.1.0\ncommit=%s\n' "$old" >"$work/inst/.homefield-ref"

version_run V_GH_FAIL=1 V_COMMIT="$old"
record "gh failing: exit 0, one line, none of gh's output" "0/2/no/no" "$rc/$(printf '%s\n' "$out" | wc -l | tr -d ' ')/$(has "$out" 'Bad credentials')/$(has "$out" 'HTTP 401')"
record "...naming what failed" "yes" "$(has "$out" 'homefield: could not check for updates (gh could not read v0.1.0 in acme/tool; see gh auth status)')"

version_run V_COMMIT="not a sha"
record "an answer that is not a commit: could not check, exit 0" "0/yes" "$rc/$(has "$out" 'could not check for updates (unexpected answer from gh')"

printf 'repo=acme/tool\nref=v0.1.0\ncommit=\n' >"$work/inst/.homefield-ref"
version_run V_COMMIT="$new"
record "no commit recorded: could not check, gh not called" "0/yes/0" "$rc/$(has "$out" 'could not check for updates (.homefield-ref records no commit)')/$(called 'gh api')"

summary
