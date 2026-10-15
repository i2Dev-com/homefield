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
for t in awk cat dirname git sleep tr; do ln -s "$(command -v "$t")" "$stubs/$t"; done
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
    # The status of an existing VM only: LIMA_V2_STATUS for the v2 instance
    # (ci-runner), LIMA_STATUS for any other.
    for last; do :; done
    if [ "$last" = ci-runner ]; then printf '%s' "${LIMA_V2_STATUS:-}"; else printf '%s' "${LIMA_STATUS:-}"; fi
    ;;
  shell)
    case "$*" in
      *"test -e /Users"*)
        [ -n "${LIMA_SEES_USERS:-}" ] && exit 0
        exit 1
        ;;
    esac
    if [ -n "${LIMA_SHELL_FAIL:-}" ]; then echo "limactl: could not connect" >&2; exit 1; fi
    printf '%s' "${LIMA_SHELL_OUT:-}"
    ;;
esac
EOF
chmod +x "$stubs/uname" "$stubs/limactl"

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

run_fn LIMA_STATUS=Running -- cmd_install --url not-a-url
record "a bad URL is refused before an existing VM is touched" "nonzero/yes/0" "$(nonzero "$rc")/$(has "$out" '--url must be')/$(called 'limactl start')"

# ── a ci-runner v2 VM left behind ──────────────────────────────────────────
echo "leftover v2 VM"
v2_ref='Migrating from ci-runner (v2)'
run_fn LIMA_V2_STATUS=Running -- cmd_install --url https://github.com/acme
record "install: v2 VM and no homefield VM: refused, nothing created or started" "nonzero/yes/0/0" "$(nonzero "$rc")/$(has "$out" "$v2_ref")/$(called 'limactl create')/$(called 'limactl start')"
record "...saying v3 does not upgrade it in place, and how to override" "yes/yes" "$(has "$out" 'does not upgrade it in place')/$(has "$out" 'pass --instance or set HOMEFIELD_INSTANCE')"
record "...before any gh call (no group is created either)" "0" "$(called '^gh ')"

run_fn LIMA_V2_STATUS=Running LIMA_STATUS=Running -- cmd_install --url not-a-url
record "install: a homefield VM exists too: not refused for the v2 VM" "nonzero/no/yes" "$(nonzero "$rc")/$(has "$out" "$v2_ref")/$(has "$out" '--url must be')"

run_fn LIMA_V2_STATUS=Running HOMEFIELD_INSTANCE=other -- cmd_install
record "install: HOMEFIELD_INSTANCE set: the instance is deliberate, not refused" "nonzero/no/yes" "$(nonzero "$rc")/$(has "$out" "$v2_ref")/$(has "$out" '--url is required')"

run_fn LIMA_V2_STATUS=Running -- main --instance other install
record "install: --instance given: the instance is deliberate, not refused" "nonzero/no/yes" "$(nonzero "$rc")/$(has "$out" "$v2_ref")/$(has "$out" '--url is required')"

run_fn LIMA_V2_STATUS=Running -- main --instance ci-runner install
record "install: --instance ci-runner is the v2 VM itself, not a leftover" "no" "$(has "$out" 'does not upgrade it in place')"

run_fn -- cmd_install
record "install: no v2 VM: unchanged" "nonzero/no/yes" "$(nonzero "$rc")/$(has "$out" "$v2_ref")/$(has "$out" '--url is required')"

# The other commands that stop on a missing VM name the v2 one.
run_fn LIMA_V2_STATUS=Running -- cmd_upgrade
record "upgrade: no homefield VM, v2 VM present: the hint is added" "nonzero/yes/yes" "$(nonzero "$rc")/$(has "$out" 'no VM homefield')/$(has "$out" "$v2_ref")"
run_fn -- cmd_upgrade
record "upgrade: no VM, no v2 VM: no hint" "nonzero/yes/no" "$(nonzero "$rc")/$(has "$out" 'no VM homefield')/$(has "$out" 'ci-runner')"
run_fn LIMA_V2_STATUS=Running -- cmd_uninstall
record "uninstall: the hint is added" "nonzero/yes/yes" "$(nonzero "$rc")/$(has "$out" 'no VM homefield')/$(has "$out" "$v2_ref")"
run_fn -- cmd_uninstall
record "uninstall: no v2 VM: no hint" "nonzero/no" "$(nonzero "$rc")/$(has "$out" 'ci-runner')"
run_fn LIMA_V2_STATUS=Running -- cmd_status
record "status: not created, with the hint" "0/yes/yes" "$rc/$(has "$out" 'VM homefield: not created')/$(has "$out" "$v2_ref")"
run_fn -- cmd_status
record "status: not created, no v2 VM: no hint" "0/yes/no" "$rc/$(has "$out" 'VM homefield: not created')/$(has "$out" 'ci-runner')"
run_fn LIMA_V2_STATUS=Running -- cmd_memory
record "memory: the hint is added" "nonzero/yes/yes" "$(nonzero "$rc")/$(has "$out" 'VM homefield is not running')/$(has "$out" "$v2_ref")"
run_fn LIMA_V2_STATUS=Stopped -- main --instance ci-runner status
record "the v2 VM asked for by name: no hint about itself" "0/no" "$rc/$(has "$out" 'does not upgrade')"

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

# ── version ────────────────────────────────────────────────────────────────
echo "version"
mkdir -p "$work/inst/bin" "$work/bare/bin"
cp "$ROOT/bin/homefield" "$work/inst/bin/homefield"
cp "$ROOT/bin/homefield" "$work/bare/bin/homefield"
printf 'repo=acme/tool\nref=v3\ncommit=0123456789abcdef0123456789abcdef01234567\n' >"$work/inst/.homefield-ref"
out="$(env -i PATH="$stubs" "$BASH" "$work/inst/bin/homefield" version 2>&1)"
record "an install.sh copy reports its ref, short commit and source" "homefield v3 (0123456), installed from acme/tool in $work/inst" "$out"
out="$(env -i PATH="$stubs" GIT_CEILING_DIRECTORIES="$work" "$BASH" "$work/bare/bin/homefield" version 2>&1)"
record "neither a ref file nor a checkout" "homefield (version unknown), in $work/bare" "$out"
out="$(env -i PATH="$stubs" "$BASH" "$ROOT/bin/homefield" version 2>&1)"
record "a checkout says so" "yes" "$(has "$out" 'from a checkout in')"

summary
