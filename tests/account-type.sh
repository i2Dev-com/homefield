#!/usr/bin/env bash
# `install` and the kind of account that owns the URL: a personal account or an
# organization, found by looking the owner up (gh, else curl) or forced with
# --personal / --org, and what each means for the registration (a repository
# for a personal account, no runner group, and the closing advice).
# bin/homefield is sourced (HOMEFIELD_SOURCE_ONLY=1) to call functions on their
# own, with stub gh, curl and limactl that record their calls. Nothing reaches
# GitHub or a VM, and the account lookup never reaches the real API.
#
# Run:  bash tests/account-type.sh
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
# gh: the owner lookup (GH_OWNER_TYPE, or a failure with GH_USERS_FAIL), the
# runner-group calls, and an empty runner list. Every call is recorded.
cat >"$stubs/gh" <<'EOF'
#!/bin/sh
echo "gh $*" >>"$CALLS"
case "$*" in
  *users/*)
    [ -z "${GH_USERS_FAIL:-}" ] || { echo '{"message":"Not Found"}'; exit 1; }
    echo "${GH_OWNER_TYPE:-Organization}"
    ;;
  *"-X POST"*) echo '{"id": 7}' ;;
  *runner-groups*) printf 'Default\tall\tfalse\nhomefield-ci\tselected\tfalse\n' ;;
  *actions/runners*) ;;
esac
EOF
# curl: the public API's answer for the owner (CURL_TYPE), or a failure.
cat >"$stubs/curl" <<'EOF'
#!/bin/sh
echo "curl $*" >>"$CALLS"
[ -z "${CURL_FAIL:-}" ] || exit 22
printf '{\n  "login": "x",\n  "type": "%s",\n  "site_admin": false\n}\n' "${CURL_TYPE:-User}"
EOF
# A Mac, and a Lima with no VM (or one in the state LIMA_STATUS names).
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
    echo "other-vm Stopped"
    [ -z "${LIMA_STATUS:-}" ] || echo "homefield ${LIMA_STATUS}"
    ;;
esac
EOF
cat >"$stubs/scutil" <<'EOF'
#!/bin/sh
echo "Test-Mac"
EOF
chmod +x "$stubs/gh" "$stubs/curl" "$stubs/uname" "$stubs/limactl" "$stubs/scutil"
for t in awk cat dirname git grep head mktemp sed sh sleep tr; do ln -s "$(command -v "$t")" "$stubs/$t"; done

# run_fn [VAR=value ...] -- <function> [args]: sets out and rc. Stdin is
# $RUN_IN (typed answers), else nothing, so there is no terminal either way.
RUN_IN=/dev/null
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
    "$BASH" -c '. "$1"; shift; "$@"' _ "$ROOT/bin/homefield" "$@" 2>&1 <"$RUN_IN")"
  rc=$?
}
called() { grep -c -e "$1" "$calls" || true; }
# mode_of <url> <force> [VAR=value ...]: ACCOUNT_MODE after check_scope_owner.
mode_of() {
  local url="$1" force="$2"
  shift 2
  # shellcheck disable=SC2016  # expanded by the inner bash
  run_fn U="$url" F="$force" "$@" -- eval 'ACCOUNT_FORCE="$F"; check_scope_owner "$U"; echo "mode=$ACCOUNT_MODE"'
  echo "$out" | sed -n 's/^mode=//p'
}
# A terminal is not available to a test, so say there is one.
tty_yes='have_terminal() { true; }; '

# ── the owner lookup ───────────────────────────────────────────────────────
echo "detection"
# shellcheck disable=SC2016  # expanded by the inner bash
run_fn GH_OWNER_TYPE=Organization -- eval 'check_scope_owner https://github.com/acme; echo "mode=$ACCOUNT_MODE"'
record "an organization's owner URL: org" "0/mode=org/1" "$rc/$(echo "$out" | grep '^mode=')/$(called 'users/acme')"
# shellcheck disable=SC2016  # expanded by the inner bash
run_fn GH_OWNER_TYPE=User -- eval 'check_scope_owner https://github.com/acme/app; echo "mode=$ACCOUNT_MODE"'
record "a personal account's repository URL: personal" "0/mode=personal/1" "$rc/$(echo "$out" | grep '^mode=')/$(called 'users/acme')"
# shellcheck disable=SC2016  # expanded by the inner bash
run_fn GH_OWNER_TYPE=Organization -- eval 'check_scope_owner https://github.com/acme/app; echo "mode=$ACCOUNT_MODE"'
record "an organization's repository URL: org (looked up now; it was not before)" "0/mode=org/1" "$rc/$(echo "$out" | grep '^mode=')/$(called 'users/acme')"
# shellcheck disable=SC2016  # expanded by the inner bash
run_fn GH_OWNER_TYPE=Organization -- eval 'check_scope_owner https://github.com/acme/app/; echo "mode=$ACCOUNT_MODE"'
record "a trailing slash is fine" "mode=org" "$(echo "$out" | grep '^mode=')"
# shellcheck disable=SC2016  # expanded by the inner bash
run_fn -- eval 'check_scope_owner not-a-url; echo "mode=$ACCOUNT_MODE"'
record "a URL of another shape is left to api_scope: no lookup" "0/mode=/0" "$rc/$(echo "$out" | grep '^mode=')/$(called 'users/')"

run_fn GH_OWNER_TYPE=User -- check_scope_owner https://github.com/someone
record "a personal owner URL with no terminal: refused, naming the flag to use" "nonzero/yes/yes" \
  "$(nonzero "$rc")/$(has "$out" 'someone is a personal account')/$(has "$out" '--url https://github.com/someone/<repo>')"
# shellcheck disable=SC2016  # expanded by the inner bash
run_fn GH_OWNER_TYPE=User -- eval "$tty_yes"'check_scope_owner https://github.com/someone; echo "mode=$ACCOUNT_MODE"'
record "...with a terminal: accepted, the repository is asked for later" "0/mode=personal" "$rc/$(echo "$out" | grep '^mode=')"

# The public API when gh fails or is missing.
# shellcheck disable=SC2016  # expanded by the inner bash
run_fn GH_USERS_FAIL=1 CURL_TYPE=User -- eval 'check_scope_owner https://github.com/acme/app; echo "mode=$ACCOUNT_MODE"'
record "gh fails: the public API answers with curl" "mode=personal/1" "$(echo "$out" | grep '^mode=')/$(called '^curl .*api.github.com/users/acme')"
mv "$stubs/gh" "$work/gh.away"
# shellcheck disable=SC2016  # expanded by the inner bash
run_fn CURL_TYPE=Organization -- eval 'check_scope_owner https://github.com/acme; echo "mode=$ACCOUNT_MODE"'
record "no gh: curl answers" "mode=org/0" "$(echo "$out" | grep '^mode=')/$(called '^gh ')"
mv "$work/gh.away" "$stubs/gh"

# The API cannot be reached, or does not know the account.
run_fn GH_USERS_FAIL=1 CURL_FAIL=1 -- check_scope_owner https://github.com/acme
record "owner URL, nothing answers: fatal, and names --org and --personal" "nonzero/yes/yes/yes" \
  "$(nonzero "$rc")/$(has "$out" 'could not find acme on GitHub')/$(has "$out" '--org')/$(has "$out" '--personal')"
# shellcheck disable=SC2016  # expanded by the inner bash
run_fn GH_USERS_FAIL=1 CURL_FAIL=1 -- eval 'check_scope_owner https://github.com/acme/app; echo "mode=[$ACCOUNT_MODE]"'
record "repository URL, nothing answers: not fatal, mode unknown" "0/mode=[]" "$rc/$(echo "$out" | grep '^mode=')"
run_fn GH_OWNER_TYPE=Bot -- check_scope_owner https://github.com/acme
record "a type that is neither user nor organization is not an answer" "nonzero/yes" "$(nonzero "$rc")/$(has "$out" 'could not find acme')"

# ── --personal and --org ───────────────────────────────────────────────────
echo "forcing"
record "--personal: personal, whatever GitHub would say" "personal" "$(mode_of https://github.com/acme/app personal GH_OWNER_TYPE=Organization)"
record "...and the lookup was skipped (no gh, no curl call)" "0/0" "$(called 'users/')/$(called '^curl')"
record "--org: org, whatever GitHub would say" "org" "$(mode_of https://github.com/someone/app org GH_OWNER_TYPE=User)"
record "...and the lookup was skipped" "0/0" "$(called 'users/')/$(called '^curl')"
record "--org with an owner URL: org, the lookup skipped even when it would fail" "org/0/0" \
  "$(mode_of https://github.com/acme org GH_USERS_FAIL=1 CURL_FAIL=1)/$(called 'users/')/$(called '^curl')"
record "--personal and nothing answers: personal, not fatal" "personal" "$(mode_of https://github.com/someone/app personal GH_USERS_FAIL=1 CURL_FAIL=1)"
# shellcheck disable=SC2016  # expanded by the inner bash
run_fn -- eval 'ACCOUNT_FORCE=personal; check_scope_owner https://github.com/someone'
record "--personal with an owner URL follows the personal rule: refused without a terminal" "nonzero/yes/0" "$(nonzero "$rc")/$(has "$out" '--url https://github.com/someone/<repo>')/$(called 'users/')"

run_fn -- cmd_install --personal --org
record "--personal --org: an error" "nonzero/yes" "$(nonzero "$rc")/$(has "$out" '--personal and --org cannot be used together')"
run_fn -- cmd_install --org --personal
record "--org --personal: an error, either order" "nonzero/yes" "$(nonzero "$rc")/$(has "$out" '--personal and --org cannot be used together')"
record "...before anything is asked of GitHub or Lima" "0/0" "$(called '^gh')/$(called '^limactl')"

# ── ask_personal_repo ──────────────────────────────────────────────────────
echo "asking for the repository"
printf 'app\n' >"$work/in"
RUN_IN="$work/in" run_fn -- ask_personal_repo https://github.com/someone
record "a repository name becomes its URL" "yes" "$(has "$out" 'https://github.com/someone/app')"
record "...after explaining why it is asked" "yes" "$(has "$out" 'someone is a personal account')"
printf 'https://github.com/Someone/other/\n' >"$work/in"
RUN_IN="$work/in" run_fn -- ask_personal_repo https://github.com/someone/
record "a full URL of the account is used as typed (owner compared without case, no trailing slash)" "yes" "$(has "$out" 'https://github.com/Someone/other')"
printf 'https://github.com/acme/app\n' >"$work/in"
RUN_IN="$work/in" run_fn -- ask_personal_repo https://github.com/someone
record "a repository of another owner is refused" "nonzero/yes" "$(nonzero "$rc")/$(has "$out" 'not a repository of someone')"
printf 'a/b\n' >"$work/in"
RUN_IN="$work/in" run_fn -- ask_personal_repo https://github.com/someone
record "a name that is not one is refused" "nonzero/yes" "$(nonzero "$rc")/$(has "$out" 'not a repository of someone')"
printf '\n' >"$work/in"
RUN_IN="$work/in" run_fn -- ask_personal_repo https://github.com/someone
record "no answer is refused" "nonzero/yes" "$(nonzero "$rc")/$(has "$out" 'no repository given')"

# ── no runner group on a personal account ──────────────────────────────────
echo "ensure_group"
# shellcheck disable=SC2016  # expanded by the inner bash
run_fn -- eval 'ACCOUNT_MODE=personal; ensure_group https://github.com/someone/app homefield-ci; echo "state=$GROUP_STATE"'
record "personal: GROUP_STATE=personal, no gh call" "0/state=personal/0" "$rc/$(echo "$out" | grep '^state=')/$(wc -l <"$calls" | tr -d ' ')"
# shellcheck disable=SC2016  # expanded by the inner bash
run_fn -- eval 'ACCOUNT_MODE=personal; ensure_group https://github.com/someone/app "Local CI"; echo "state=$GROUP_STATE"'
record "...whatever the group's name" "state=personal/0" "$(echo "$out" | grep '^state=')/$(wc -l <"$calls" | tr -d ' ')"
# shellcheck disable=SC2016  # expanded by the inner bash
run_fn -- eval 'ACCOUNT_MODE=org; ensure_group https://github.com/acme homefield-ci; echo "state=$GROUP_STATE"'
record "org: the groups are still looked up" "state=narrow/1" "$(echo "$out" | grep '^state=')/$(called 'runner-groups')"
# shellcheck disable=SC2016  # expanded by the inner bash
run_fn -- eval 'ACCOUNT_MODE=""; ensure_group https://github.com/acme/app homefield-ci; echo "state=$GROUP_STATE"'
record "unknown (a repository URL): as before, repo" "state=repo/0" "$(echo "$out" | grep '^state=')/$(wc -l <"$calls" | tr -d ' ')"

# ── what is said about the account ─────────────────────────────────────────
echo "announce_account"
# shellcheck disable=SC2016  # expanded by the inner bash
run_fn -- eval 'ACCOUNT_MODE=personal; announce_account https://github.com/someone/app ""'
record "personal, detected: says so, and names the repository" "yes/yes" "$(has "$out" 'personal account (someone), detected')/$(has "$out" 'for the repository someone/app only')"
record "...both limits, GitHub's and HomeField's, kept apart" "yes/yes/no" \
  "$(has "$out" 'GitHub: no account-wide runners and no runner groups, so each repository registers on its own')/$(has "$out" 'HomeField: one VM runs one runner (until #14), so each personal repository needs its own --instance')/$(has "$out" '--group')"
# shellcheck disable=SC2016  # expanded by the inner bash
run_fn -- eval 'ACCOUNT_MODE=personal; ACCOUNT_FORCE=personal; announce_account https://github.com/someone/app Default'
record "personal, forced: says so, and that --group is ignored" "yes/yes" "$(has "$out" 'personal account (someone), forced by --personal')/$(has "$out" '--group Default is ignored')"
# shellcheck disable=SC2016  # expanded by the inner bash
run_fn -- eval 'ACCOUNT_MODE=org; announce_account https://github.com/acme ""'
record "org, detected: one line" "organization (acme), detected.|1" "$(echo "$out" | sed -n 's/^homefield: //p')|$(echo "$out" | wc -l | tr -d ' ')"
# shellcheck disable=SC2016  # expanded by the inner bash
run_fn -- eval 'ACCOUNT_MODE=org; ACCOUNT_FORCE=org; announce_account https://github.com/acme/app ""'
record "org, forced" "yes" "$(has "$out" 'organization (acme), forced by --org.')"
# shellcheck disable=SC2016  # expanded by the inner bash
run_fn -- eval 'ACCOUNT_MODE=""; announce_account https://github.com/acme/app ""'
record "unknown: a note that the type was not checked, naming the flags" "yes/yes/yes" \
  "$(has "$out" 'could not check whether acme is a personal account or an organization')/$(has "$out" '--personal or --org')/$(has "$out" 'going on')"

# ── install: the order, and what is asked of GitHub ────────────────────────
echo "install"
created() { [ "$(called 'limactl create')" -gt 0 ] && echo yes || echo no; }

run_fn GH_OWNER_TYPE=User -- cmd_install --url https://github.com/someone/app
record "no VM, a personal repository: registration goes on to the VM" "yes" "$(created)"
record "...says personal, detected, with the limits" "yes/yes" "$(has "$out" 'personal account (someone), detected')/$(has "$out" 'needs its own --instance')"
record "...with no runner group call at all" "0/0" "$(called 'runner-groups')/$(called 'POST')"
record "...the lookup was made once" "1" "$(called 'users/someone')"

run_fn GH_OWNER_TYPE=Organization -- cmd_install --url https://github.com/acme/app
record "no VM, an organization's repository: as before" "yes/yes/no" "$(created)/$(has "$out" 'organization (acme), detected.')/$(has "$out" 'personal account')"
run_fn GH_OWNER_TYPE=Organization -- cmd_install --url https://github.com/acme
record "no VM, an organization URL: the group step runs" "yes/1/yes" "$(created)/$(called 'runner-groups')/$(has "$out" 'organization (acme), detected.')"

run_fn GH_OWNER_TYPE=Organization -- cmd_install --personal --url https://github.com/someone/app
record "--personal: personal mode with no lookup" "yes/yes/0/0" "$(created)/$(has "$out" 'forced by --personal')/$(called 'users/')/$(called 'runner-groups')"
run_fn GH_OWNER_TYPE=User -- cmd_install --org --url https://github.com/acme
record "--org: organization mode with no lookup, and the group step as for an organization" "yes/yes/0/1" "$(created)/$(has "$out" 'forced by --org')/$(called 'users/')/$(called 'runner-groups')"
run_fn GH_OWNER_TYPE=User -- cmd_install --url https://github.com/someone/app --group Default
record "--group on a personal account: ignored, with a message" "yes/yes/0" "$(created)/$(has "$out" '--group Default is ignored')/$(called 'runner-groups')"

run_fn GH_OWNER_TYPE=User -- cmd_install --url https://github.com/someone
record "no VM, a personal owner URL, no terminal: stops before the VM, naming the flag" "nonzero/yes/no" \
  "$(nonzero "$rc")/$(has "$out" '--url https://github.com/someone/<repo>')/$(created)"
run_fn GH_USERS_FAIL=1 CURL_FAIL=1 -- cmd_install --url https://github.com/acme
record "no VM, an owner that cannot be looked up: stops before the VM, naming the flags" "nonzero/yes/no" \
  "$(nonzero "$rc")/$(has "$out" 'pass --org to skip the check')/$(created)"
run_fn GH_USERS_FAIL=1 CURL_FAIL=1 -- cmd_install --url https://github.com/acme/app
record "no VM, a repository whose owner cannot be looked up: a note, and it goes on" "yes/yes" "$(has "$out" 'could not check whether acme')/$(created)"
run_fn GH_USERS_FAIL=1 CURL_FAIL=1 -- cmd_install --org --url https://github.com/acme
record "...an owner URL with --org: goes on" "yes" "$(created)"

# With a VM that is already there, a URL that was given is still checked before
# the VM is touched; a registered instance is only upgraded.
run_fn LIMA_STATUS=Running GH_OWNER_TYPE=User -- cmd_install --url https://github.com/someone
record "a VM exists, a personal owner URL, no terminal: refused before the VM is started" "nonzero/yes/0" \
  "$(nonzero "$rc")/$(has "$out" '--url https://github.com/someone/<repo>')/$(called 'limactl start')"
run_fn LIMA_STATUS=Running GH_OWNER_TYPE=User -- cmd_install --url https://github.com/someone/app
record "a VM exists, a personal repository URL: looked up before the VM is touched" "1" "$(called 'users/someone')"
run_fn LIMA_STATUS=Running GH_OWNER_TYPE=User -- cmd_install
record "a VM exists and no URL: nothing is looked up" "0" "$(called 'users/')"

# On a terminal, a personal owner URL is asked for its repository, and the
# registration goes on for that repository, in personal mode.
printf 'app\n' >"$work/in"
# shellcheck disable=SC2016  # expanded by the inner bash
RUN_IN="$work/in" run_fn GH_OWNER_TYPE=User -- eval "$tty_yes"'url=https://github.com/someone; group=""; name=mac-homefield; replace=0; prepare_registration; echo "url=$url state=$GROUP_STATE mode=$ACCOUNT_MODE"'
record "a terminal, a personal owner URL: asks, then registers that repository without a group" "0/yes/url=https://github.com/someone/app state=personal mode=personal/0" \
  "$rc/$(has "$out" 'someone is a personal account')/$(echo "$out" | grep '^url=')/$(called 'runner-groups')"
record "...and announces the repository, not just the owner" "yes" "$(has "$out" 'for the repository someone/app only')"

# ── the closing advice ─────────────────────────────────────────────────────
echo "registered_next_steps"
# shellcheck disable=SC2016  # expanded by the inner bash
next() { run_fn GS="$1" G="$2" U="$3" -- eval 'GROUP_STATE="$GS"; registered_next_steps "$G" "$U"'; }
next personal homefield-ci https://github.com/someone/app
record "personal: serves only that repository" "0/yes" "$rc/$(has "$out" 'It serves only someone/app')"
record "...no runner group advice" "no/no/no/no" "$(has "$out" 'runner group homefield-ci')/$(has "$out" 'Default group')/$(has "$out" 'Narrow')/$(has "$out" 'repositories added to it')"
record "...another repository needs its own registration and VM" "yes" "$(has "$out" 'homefield install --instance <name> --url https://github.com/<owner>/<repo>')"
record "...then the common lines" "yes/yes" "$(has "$out" 'Route jobs from a repository')/$(has "$out" 'bin/homefield status')"
next personal homefield-ci https://github.com/someone/app/
record "...a trailing slash on the URL is dropped" "yes" "$(has "$out" 'It serves only someone/app:')"
next narrow homefield-ci https://github.com/acme
record "narrow: the runner group's repositories" "yes/no" "$(has "$out" 'It is in the runner group homefield-ci, which admits only the')/$(has "$out" 'serves only')"
next created "Local CI" https://github.com/acme
record "created: the same, with the group's name" "yes" "$(has "$out" 'It is in the runner group Local CI')"
next default Default https://github.com/acme
record "default: every repository can use it" "yes" "$(has "$out" 'It is in the Default group')"
next wide homefield-ci https://github.com/acme
record "wide: narrow it" "yes" "$(has "$out" 'Narrow the runner group homefield-ci as warned above')"
next unchecked homefield-ci https://github.com/acme
record "unchecked: check it by hand" "yes" "$(has "$out" 'Check the runner group homefield-ci by hand')"
next repo homefield-ci https://github.com/acme/app
record "repo: only the common lines" "yes/no/no" "$(has "$out" 'Route jobs from a repository')/$(has "$out" 'runner group')/$(has "$out" 'serves only')"

summary
