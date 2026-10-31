#!/usr/bin/env bash
# `homefield reset` (#127): rolls back a complete or half-finished install of
# one instance. The real cmd_reset runs, with the guest side run in a scratch
# runner directory (svc.sh, config.sh, systemctl, sudo and limactl are stubs, as
# in tests/uninstall.sh, so the real deregistration script runs) and a stub gh
# that records every call and answers the runner-group calls from files and
# variables. The VM's status, whether GitHub lists the runner and whether a job
# runs come from the environment, never from this machine, which is itself a
# runner. HOME, the state directory, the tool's install directory and its bin
# directory are temp dirs, and the runner-group DELETE is asserted on the
# recorded gh calls. Nothing reaches GitHub or a VM.
#
# Run:  bash tests/reset.sh
# shellcheck disable=SC2016  # the stub bodies expand when they run, not when defined
set -uo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
stubs="$work/stubs"
home="$work/runner"
units="$work/units"
state="$work/state"
share="$work/share"
bin="$work/bin"
mkdir -p "$stubs" "$work/home"
unit="actions.runner.acme.test.service"
DEL='gh api -X DELETE orgs/acme/actions/runner-groups/7$'

stub() { printf '#!/usr/bin/env bash\n%s\n' "$2" >"$stubs/$1"; chmod +x "$stubs/$1"; }
stub sudo 'while [ $# -gt 0 ]; do case "$1" in -u) shift 2 ;; -n|--preserve-env=*) shift ;; *) break ;; esac; done
exec "$@"'
stub limactl 'echo "limactl $*" >>"$LOG"
case "$1" in
  copy) [ "${FAIL_COPY:-}" != 1 ] ;;
  delete) [ "${FAIL_DELETE:-}" != 1 ] ;;
esac'
stub chown 'exit 0'
stub id 'case "$1" in -u) echo 0 ;; *) exec /usr/bin/id "$@" ;; esac'
stub pgrep 'case "$*" in *"[R]unner.Worker"*) ;; *) exit 0 ;; esac
case "${JOB:-idle}" in
  running) exit 0 ;;
  later) n="$(cat "$WORK/pgrep-n" 2>/dev/null || echo 0)"; echo $((n + 1)) >"$WORK/pgrep-n"; [ "$n" -ge 1 ] ;;
  *) exit 1 ;;
esac'
stub systemctl 'echo "systemctl $*" >>"$LOG"
case "$1" in
  stop) [ -e "$UNITS/$2" ] || exit 5; rm -f "$HOME_DIR/active" ;;
  show) [ -e "$UNITS/${!#}" ] && echo loaded || echo not-found ;;
  start) [ -e "$UNITS/$2" ] || exit 5; : >"$HOME_DIR/active" ;;
  enable) [ -e "$UNITS/$2" ] || exit 1; : >"$HOME_DIR/enabled" ;;
  disable) rm -f "$HOME_DIR/enabled" ;;
esac'
# brew, for the default place of the command (--remove-tool without HOMEFIELD_BIN_DIR).
stub brew 'echo "$BREW_PREFIX"'
# gh: GH_GROUPS_FILE is the runner groups (name, visibility, public, id; tab
# separated), GH_GROUP_RUNNERS the ids of the runners in any group; each can
# fail (GH_LIST_FAIL, GH_RUNNERS_FAIL), and so can the DELETE (GH_DELETE_FAIL).
cat >"$stubs/gh" <<'EOF'
#!/bin/sh
echo "gh $*" >>"$LOG"
case "$*" in
  *"-X DELETE"*)
    [ -z "${GH_DELETE_FAIL:-}" ] || { echo "gh: HTTP 403 (Must have admin rights)" >&2; exit 1; }
    ;;
  *runner-groups/*/runners*)
    if [ -n "${GH_RUNNERS_FAIL:-}" ]; then echo '{"message":"Not Found"}'; exit 1; fi
    for id in ${GH_GROUP_RUNNERS:-}; do echo "$id"; done
    ;;
  *runner-groups*)
    if [ -n "${GH_LIST_FAIL:-}" ]; then echo '{"message":"Must have admin rights"}'; exit 1; fi
    cat "$GH_GROUPS_FILE"
    ;;
esac
EOF
chmod +x "$stubs/gh"

printf 'Default\tall\tfalse\t1\nhomefield-ci\tselected\tfalse\t7\n' >"$work/groups-ok"
printf 'Default\tall\tfalse\t1\nOther\tselected\tfalse\t7\n' >"$work/groups-renamed"
printf 'Default\tall\tfalse\t1\nhomefield-ci\tselected\tfalse\t9\n' >"$work/groups-new-id"
printf 'Default\tall\tfalse\t1\nHomeField-CI\tselected\tfalse\t7\n' >"$work/groups-case"

# What a runner directory has: the scripts the runner ships, with the service
# installed and the runner registered (as tests/uninstall.sh).
fresh() {
  rm -rf "${work:?}/runner" "$units" "$state" "$work/log" "$work/pgrep-n"
  mkdir -p "$home" "$units"
  : >"$home/.runner"
  echo "$unit" >"$home/.service"
  : >"$units/$unit"
  : >"$home/enabled"
  : >"$home/active"
  cat >"$home/svc.sh" <<'EOF'
#!/bin/sh
echo "svc.sh $*" >>"$LOG"
case "$1" in
  uninstall)
    rm -f "$HOME_DIR/active"
    systemctl disable actions.runner.acme.test.service
    rm -f "$UNITS/actions.runner.acme.test.service" "$HOME_DIR/.service"
    systemctl daemon-reload
    ;;
  install)
    : >"$UNITS/actions.runner.acme.test.service"
    systemctl enable actions.runner.acme.test.service
    echo "actions.runner.acme.test.service" >"$HOME_DIR/.service"
    ;;
esac
EOF
  cat >"$home/config.sh" <<'EOF'
#!/bin/sh
echo "config.sh $* token-in-env=$([ -n "${ACTIONS_RUNNER_INPUT_TOKEN:-}" ] && echo yes || echo no)" >>"$LOG"
[ "${FAIL_REMOVE:-}" != 1 ] || { echo "config.sh: injected failure" >&2; exit 1; }
rm -f "$HOME_DIR/.runner"
EOF
  chmod +x "$home/svc.sh" "$home/config.sh"
  : >"$work/log"
}
sed -e "s|/opt/actions-runner|$home|g" -e "s|/etc/systemd/system|$units|g" \
  "$ROOT/vm/provision.sh" >"$work/provision.sh"

# set_state <org/name/id>: install's record that it created the group.
set_state() {
  mkdir -p "$state"
  printf 'group_created=%s\n' "$1" >"$state/resettest.state"
}
state_file() { printf '%s/resettest.state' "$state"; }

# cmd_reset, in a shell of its own. VM is the status Lima gives the VM (none
# for no VM), GH_ON whether GitHub lists the runner (0 yes, 1 no, 2 not
# asked), TTY=1 a terminal that answers ANSWER. The probes are the real ones.
cat >"$work/harness.sh" <<'EOF'
HOMEFIELD_SOURCE_ONLY=1
. "$ROOT_DIR/bin/homefield"
RUNNER_HOME="$HOME_DIR"
GUEST_PROVISION="$WORK/provision.sh"
check_host() { :; }
vm_status() { case "${VM:-Running}" in none) ;; *) echo "${VM:-Running}" ;; esac; }
runner_setting() { printf '%s\n' https://github.com/acme 42; }
get_token() { echo "get_token $1" >>"$LOG"; echo tok; }
runner_on_github() { echo "runner_on_github $*" >>"$LOG"; return "${GH_ON:-0}"; }
have_terminal() { [ "${TTY:-}" = 1 ]; }
guest() { "$@" </dev/null; }
guest_stdin() { "$@"; }
cmd_reset "$@"
EOF

# run [VAR=value ...] -- [reset options]: sets out and rc. HOMEFIELD_YES is
# set unless a case says otherwise; nothing else of the environment is kept.
run() {
  local envs=() answer="" e
  while [ $# -gt 0 ] && [ "$1" != -- ]; do
    envs+=("$1")
    shift
  done
  shift
  for e in "${envs[@]+"${envs[@]}"}"; do
    case "$e" in ANSWER=*) answer="${e#ANSWER=}" ;; esac
  done
  out="$(printf '%s\n' "$answer" | env -i PATH="$stubs:$PATH" HOME="$work/home" LOG="$work/log" HOME_DIR="$home" UNITS="$units" \
    ROOT_DIR="$ROOT" WORK="$work" GH_GROUPS_FILE="$work/groups-ok" BREW_PREFIX="$work/brew" \
    HOMEFIELD_INSTANCE=resettest HOMEFIELD_STATE_DIR="$state" HOMEFIELD_HOME="$share" HOMEFIELD_BIN_DIR="$bin" HOMEFIELD_YES=1 \
    "${envs[@]+"${envs[@]}"}" "$BASH" "$work/harness.sh" "$@" 2>&1)"
  rc=$?
}
has() { case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac; }
logged() { grep -c -e "$1" "$work/log" || true; }
lines() { grep -c -x -e "$1" "$work/log" || true; }
runner_state() {
  printf '%s/%s/%s/%s' "$([ -e "$home/.runner" ] && echo registered || echo removed)" \
    "$([ -e "$units/$unit" ] && echo unit || echo no-unit)" "$([ -e "$home/.service" ] && echo .service || echo no-.service)" \
    "$([ -e "$home/active" ] && echo active || echo stopped)"
}
has_state() { [ -e "$(state_file)" ] && echo state || echo no-state; }
# nothing_changed: no limactl change, no registration change, no group delete.
nothing_changed() {
  printf '%s/%s/%s/%s/%s' "$(logged 'limactl delete')" "$(logged 'limactl start')" "$(logged 'config.sh')" "$(lines "$DEL")" "$(runner_state)"
}

echo "nothing exists:"
fresh
run VM=none --
record "reset is a no-op: exit 0" "0" "$rc"
record "...says there is nothing to reset" "yes" "$(has "$out" 'nothing to reset')"
record "...needs no confirmation, with no terminal and no HOMEFIELD_YES" "yes" "$(run VM=none HOMEFIELD_YES= -- ; has "$out" 'nothing to reset')"
record "...touches nothing: no gh, no limactl, no state directory" "0/0/no" "$(logged 'gh ')/$(logged 'limactl')/$([ -e "$state" ] && echo yes || echo no)"
fresh
mkdir -p "$state"
: >"$(state_file)"
run VM=none --
record "a state file with no group in it is removed, quietly" "0/no-state" "$rc/$(has_state)"
fresh
run VM=none -- --remove-tool
record "--remove-tool with no tool installed: exit 0, says none was found" "0/yes" "$rc/$(has "$out" 'no homefield wrapper of this install found')"
record "...and that the install dir was not put there by install.sh" "yes" "$(has "$out" 'was not put there by install.sh')"

echo "full rollback of a registered runner, with the group install created:"
fresh
set_state acme/homefield-ci/7
mkdir -p "$state"
printf 'group_created=other/x/1\n' >"$state/other.state"
run GH_ON=0 --
record "reset succeeds" "0" "$rc"
record "...deregistered with a remove token, service uninstalled" "removed/no-unit/no-.service/stopped" "$(runner_state)"
record "...GitHub asked about the runner by URL and id, a token fetched, config.sh got it" "1/1/1" "$(logged 'runner_on_github https://github.com/acme 42')/$(logged 'get_token remove')/$(logged 'config.sh remove token-in-env=yes')"
record "...the VM was deleted once" "1" "$(logged 'limactl delete --force resettest')"
record "...the group was deleted by id, once" "1" "$(lines "$DEL")"
record "...the state file is removed, another instance's is not" "no-state/yes" "$(has_state)/$([ -e "$state/other.state" ] && echo yes || echo no)"
record "...the report says each" "yes/yes/yes/yes" "$(has "$out" 'runner: deregistered from https://github.com/acme')/$(has "$out" 'VM resettest: deleted')/$(has "$out" 'runner group acme/homefield-ci (id 7): deleted')/$(has "$out" 'resettest.state: removed')"

echo "GitHub removed the runner:"
fresh
run GH_ON=1 --
record "reset succeeds, removing the VM's copy only, with no token" "0/removed/0/1/1" "$rc/$(runner_state | cut -d/ -f1)/$(logged 'get_token')/$(logged 'config.sh remove --local token-in-env=no')/$(logged 'limactl delete --force')"
record "...the report says so" "yes" "$(has "$out" 'removed from the VM only, GitHub no longer listed it')"

echo "a VM that never registered (a failed install):"
fresh
rm -f "$home/.runner"
run --
record "reset succeeds" "0" "$rc"
record "...says it is not registered, runs no config.sh, deletes the VM" "yes/0/1" "$(has "$out" 'runner: not registered')/$(logged 'config.sh')/$(logged 'limactl delete --force')"
record "...no group was recorded: gh is never called" "0" "$(logged 'gh ')"

echo "no VM, but install recorded the group it created:"
fresh
set_state acme/homefield-ci/7
run VM=none --
record "reset succeeds and deletes the group once" "0/1" "$rc/$(lines "$DEL")"
record "...no VM was asked for or deleted" "0/0" "$(logged 'limactl delete')/$(logged 'limactl start')"
record "...the state file is removed" "no-state" "$(has_state)"

echo "the group guards (VM gone, so only the guard under test can stop the delete):"
fresh
run VM=none --
record "no record of the group: gh is not asked, nothing is deleted" "0/0" "$(logged 'gh ')/$(lines "$DEL")"
fresh
set_state acme/homefield-ci/7
run VM=none -- --keep-group
record "--keep-group: kept, exit 0, gh not asked, the record stays" "0/0/0/state/yes" "$rc/$(logged 'gh ')/$(lines "$DEL")/$(has_state)/$(has "$out" 'kept, --keep-group was given')"
fresh
set_state acme/Default/1
run VM=none --
record "the Default group is never deleted" "0/0/no-state" "$rc/$(lines 'gh api -X DELETE orgs/acme/actions/runner-groups/1$')/$(has_state)"
record "...and says why" "yes" "$(has "$out" 'it is the Default group')"
fresh
set_state acme/homefield-ci/7
run VM=none GH_GROUPS_FILE="$work/groups-renamed" --
record "the recorded id is listed under another name: kept, record stays" "0/0/state/yes" "$rc/$(lines "$DEL")/$(has_state)/$(has "$out" 'is now named Other')"
fresh
set_state acme/homefield-ci/7
run VM=none GH_GROUPS_FILE="$work/groups-new-id" --
record "the recorded id is gone (a group of that name has another id): not deleted, stale record removed" "0/0/no-state/yes" "$rc/$(lines "$DEL")/$(has_state)/$(has "$out" 'not on GitHub any more')"
record "...the other group is untouched" "0" "$(lines 'gh api -X DELETE orgs/acme/actions/runner-groups/9$')"
fresh
set_state acme/homefield-ci/7
run VM=none GH_GROUPS_FILE="$work/groups-case" --
record "the name is compared ignoring case, as GitHub does" "0/1" "$rc/$(lines "$DEL")"
fresh
set_state acme/homefield-ci/7
run VM=none GH_GROUP_RUNNERS="99" --
record "another runner is in the group: kept, exit 0, record stays" "0/0/state/yes" "$rc/$(lines "$DEL")/$(has_state)/$(has "$out" 'holds 1 other runner')"
record "...the report says deleting moves its runners to Default" "yes" "$(has "$out" 'moves its runners to Default')"
fresh
set_state acme/homefield-ci/7
run VM=none GH_RUNNERS_FAIL=1 --
record "its runners cannot be listed: not deleted, exit 1, record stays" "1/0/state/yes" "$rc/$(lines "$DEL")/$(has_state)/$(has "$out" 'could not list its runners')"
record "...with the page to delete it by hand" "yes" "$(has "$out" 'https://github.com/organizations/acme/settings/actions/runner-groups')"
fresh
set_state acme/homefield-ci/7
run VM=none GH_LIST_FAIL=1 --
record "the groups cannot be listed: not deleted, exit 1, record stays" "1/0/state/yes" "$rc/$(lines "$DEL")/$(has_state)/$(has "$out" 'could not list the runner groups of acme')"
fresh
set_state acme/homefield-ci/
run VM=none --
record "no id recorded: the group is found by name, and deleted by the id GitHub lists" "0/1" "$rc/$(lines "$DEL")"
fresh
set_state acme/homefield-ci/
run VM=none GH_GROUPS_FILE="$work/groups-new-id" --
record "...the id it finds (9, not 7) is the one deleted" "1/0" "$(lines 'gh api -X DELETE orgs/acme/actions/runner-groups/9$')/$(lines "$DEL")"
fresh
set_state acme/homefield-ci/7
run VM=none GH_DELETE_FAIL=1 --
record "GitHub refuses the delete: exit 1, says why, record stays" "1/state/yes/yes" "$rc/$(has_state)/$(has "$out" 'could not delete it')/$(has "$out" 'Must have admin rights')"
fresh
mkdir -p "$state"
printf 'group_created=garbage\n' >"$(state_file)"
run VM=none --
record "a record that does not parse: no group touched, the file stays, exit 0" "0/0/state/yes" "$rc/$(logged 'gh ')/$(has_state)/$(has "$out" 'does not parse')"

echo "this instance's own runner in the group:"
fresh
set_state acme/homefield-ci/7
run GH_ON=0 GH_GROUP_RUNNERS="42" --
record "deregistered in this run and still listed (GitHub lags): the group is deleted" "0/1" "$rc/$(lines "$DEL")"
fresh
set_state acme/homefield-ci/7
run GH_ON=0 GH_GROUP_RUNNERS="42 99" --
record "...with another runner too: kept" "0/0" "$rc/$(lines "$DEL")"
fresh
set_state acme/homefield-ci/7
run VM=none GH_GROUP_RUNNERS="42" --
record "no VM, so that runner is not known to be ours: kept" "0/0" "$rc/$(lines "$DEL")"

echo "--keep-vm:"
fresh
set_state acme/homefield-ci/7
run GH_ON=0 -- --keep-vm
record "deregisters, keeps the VM, still deletes the group" "0/removed/0/1" "$rc/$(runner_state | cut -d/ -f1)/$(logged 'limactl delete')/$(lines "$DEL")"
record "...the report says the VM is kept" "yes" "$(has "$out" 'kept (--keep-vm)')"
fresh
rm -f "$home/.runner"
run VM=Running -- --keep-vm
record "--keep-vm on a VM that is not registered: nothing to do, no confirmation needed" "0/0" "$rc/$(logged 'limactl delete')"

echo "--keep-group with a registered runner:"
fresh
set_state acme/homefield-ci/7
run GH_ON=0 -- --keep-group
record "the VM goes, the group stays" "0/removed/1/0/state" "$rc/$(runner_state | cut -d/ -f1)/$(logged 'limactl delete --force')/$(lines "$DEL")/$(has_state)"

echo "a job is running:"
fresh
set_state acme/homefield-ci/7
run JOB=running --
record "reset refuses and changes nothing" "1/yes/0/0/0/0/registered/unit/.service/active/state" "$rc/$(has "$out" 'a job is running')/$(nothing_changed)/$(has_state)"
fresh
run JOB=running TTY=1 ANSWER=y HOMEFIELD_YES= --
record "...before asking anything" "1/no" "$rc/$(has "$out" 'Remove all of the above')"

echo "a job starts while the plan is being confirmed:"
fresh
set_state acme/homefield-ci/7
run JOB=later --
record "reset stops after the confirmation, before touching the runner" "1/yes/0/0/0/0/registered/unit/.service/active/state" "$rc/$(has "$out" 'a job started on resettest while you were deciding')/$(nothing_changed)/$(has_state)"
record "...it asked twice: before the plan and after the confirmation" "2" "$(cat "$work/pgrep-n")"
fresh
set_state acme/homefield-ci/7
run JOB=later VM=Stopped --
record "a stopped VM is inspected once, after it starts: no second check" "0/1" "$rc/$(cat "$work/pgrep-n")"

echo "the answer to the question:"
fresh
set_state acme/homefield-ci/7
run HOMEFIELD_YES= --
record "no terminal and no HOMEFIELD_YES: refused, saying to set it, nothing changed" "1/yes/0/0/0/0/registered/unit/.service/active/state" "$rc/$(has "$out" 'HOMEFIELD_YES=1')/$(nothing_changed)/$(has_state)"
record "...the plan was printed first" "yes/yes/yes" "$(has "$out" 'Reset of resettest will:')/$(has "$out" 'deregister the runner from https://github.com/acme')/$(has "$out" 'delete VM resettest')"
fresh
run HOMEFIELD_YES=0 --
record "HOMEFIELD_YES=0 is not yes" "1/registered" "$rc/$(runner_state | cut -d/ -f1)"
fresh
set_state acme/homefield-ci/7
run TTY=1 ANSWER=y HOMEFIELD_YES= --
record "a terminal answering y: proceeds" "0/removed/1/1" "$rc/$(runner_state | cut -d/ -f1)/$(logged 'limactl delete --force')/$(lines "$DEL")"
fresh
set_state acme/homefield-ci/7
run TTY=1 ANSWER=n HOMEFIELD_YES= --
record "...answering n: stops, nothing changed" "1/0/0/0/0/registered/unit/.service/active/state" "$rc/$(nothing_changed)/$(has_state)"
fresh
run TTY=1 ANSWER= HOMEFIELD_YES= --
record "...answering nothing: stops, nothing changed" "1/registered" "$rc/$(runner_state | cut -d/ -f1)"
fresh
run TTY=1 ANSWER=yes HOMEFIELD_YES= --
record "...answering yes: proceeds" "0/removed" "$rc/$(runner_state | cut -d/ -f1)"

echo "a stopped VM:"
fresh
run VM=Stopped TTY=1 ANSWER=n HOMEFIELD_YES= --
record "it is not started before the answer; the plan says it will be" "1/0/yes" "$rc/$(logged 'limactl start')/$(has "$out" 'start VM resettest (Stopped)')"
fresh
run VM=Stopped GH_ON=0 --
record "after the answer it is started once, then the runner is deregistered and the VM deleted" "0/1/removed/1" "$rc/$(logged 'limactl start --tty=false resettest')/$(runner_state | cut -d/ -f1)/$(logged 'limactl delete --force')"
record "...start comes first" "limactl start --tty=false resettest" "$(grep -m1 -e 'limactl' "$work/log")"

echo "the runner cannot be deregistered:"
fresh
set_state acme/homefield-ci/7
run GH_ON=0 FAIL_REMOVE=1 -- --remove-tool
record "reset fails" "1" "$rc"
record "...the VM is kept, the group is not deleted, the record stays" "0/0/state" "$(logged 'limactl delete')/$(lines "$DEL")/$(has_state)"
record "...still registered, its service back and running" "registered/unit/.service/active" "$(runner_state)"

echo "the VM cannot be deleted:"
fresh
set_state acme/homefield-ci/7
mkdir -p "$share" "$bin"
: >"$share/.homefield-ref"
run GH_ON=0 FAIL_DELETE=1 -- --remove-tool
record "reset fails, saying how to delete it by hand" "1/yes" "$rc/$(has "$out" 'limactl delete --force resettest')"
record "...the independent group step still ran" "1/no-state" "$(lines "$DEL")/$(has_state)"
record "...the tool is kept, because a step failed" "yes/yes" "$([ -e "$share/.homefield-ref" ] && echo yes || echo no)/$(has "$out" 'tool: kept, a step above failed')"
rm -rf "$share" "$bin"

echo "--remove-tool:"
# put_wrapper <dir>: the command install.sh itself writes for the install dir
# $share (its write_wrapper, taken from the file, so the two cannot drift).
put_wrapper() {
  cat >"$work/put-wrapper.sh" <<'EOF'
die() { echo "$*" >&2; exit 1; }
INSTALL_DIR="$1"
eval "$(sed -n '/^write_wrapper() {/,/^}/p' "$2")"
write_wrapper "$3"
EOF
  "$BASH" "$work/put-wrapper.sh" "$share" "$ROOT/install.sh" "$1"
}
# mk_tool: an install dir with the marker install.sh leaves, and its command.
mk_tool() {
  rm -rf "$share" "$bin"
  mkdir -p "$share/bin"
  printf '#!/bin/sh\n' >"$share/bin/homefield"
  printf 'repo=x\nref=v0\ncommit=\n' >"$share/.homefield-ref"
  put_wrapper "$bin"
}
fresh
mk_tool
run GH_ON=0 --
record "without it the tool stays" "0/yes/yes" "$rc/$([ -d "$share" ] && echo yes || echo no)/$([ -x "$bin/homefield" ] && echo yes || echo no)"
fresh
mk_tool
run GH_ON=0 -- --remove-tool
record "with it, the wrapper install.sh wrote and the install dir are removed" "0/gone/gone" "$rc/$([ -e "$bin/homefield" ] && echo there || echo gone)/$([ -e "$share" ] && echo there || echo gone)"
record "...the report says so" "yes/yes" "$(has "$out" "command $bin/homefield: removed")/$(has "$out" "tool $share: removed")"
record "...after the VM was dealt with" "1" "$(logged 'limactl delete --force')"
record "...the plan said both files are shared" "yes" "$(has "$out" 'shared by every instance on this Mac')"
fresh
mk_tool
run VM=none -- --remove-tool
record "also with no VM at all" "0/gone/gone" "$rc/$([ -e "$bin/homefield" ] && echo there || echo gone)/$([ -e "$share" ] && echo there || echo gone)"
# A foreign file of the same name, a git checkout, another install's wrapper, a link.
fresh
mk_tool
printf '#!/bin/sh\necho mine\n' >"$bin/homefield"
rm -f "$share/.homefield-ref"
run VM=none -- --remove-tool
record "a foreign homefield file and an install dir without .homefield-ref are left alone" "0/yes/yes/yes" "$rc/$([ -e "$bin/homefield" ] && echo yes || echo no)/$([ -d "$share" ] && echo yes || echo no)/$(has "$out" 'was not put there by install.sh')"
fresh
mk_tool
printf '#!/bin/sh\nexec "%s/other/bin/homefield" "$@"\n' "$work" >"$bin/homefield"
run VM=none -- --remove-tool
record "a homefield wrapper of another install dir is left alone; this install dir goes" "0/yes/gone" "$rc/$([ -e "$bin/homefield" ] && echo yes || echo no)/$([ -e "$share" ] && echo there || echo gone)"
fresh
mk_tool
mv "$bin/homefield" "$bin/real"
ln -s "$bin/real" "$bin/homefield"
run VM=none -- --remove-tool
record "a symlink named homefield is left alone" "yes" "$([ -L "$bin/homefield" ] && echo yes || echo no)"
fresh
mk_tool
rm -f "$bin/homefield"
run VM=none -- --remove-tool
record "no wrapper but an install dir: the dir goes, the missing wrapper is reported" "0/gone/yes" "$rc/$([ -e "$share" ] && echo there || echo gone)/$(has "$out" 'no homefield wrapper of this install found')"
fresh
mk_tool
rm -rf "${bin:?}"
mkdir -p "$work/home/.local/bin" "$work/brew/bin"
put_wrapper "$work/brew/bin"
put_wrapper "$work/home/.local/bin"
run VM=none HOMEFIELD_BIN_DIR= -- --remove-tool
record "without HOMEFIELD_BIN_DIR, the Homebrew bin and ~/.local/bin are both looked in" "0/gone/gone" "$rc/$([ -e "$work/brew/bin/homefield" ] && echo there || echo gone)/$([ -e "$work/home/.local/bin/homefield" ] && echo there || echo gone)"
rm -rf "$share" "$bin" "$work/brew" "$work/home/.local"
fresh
mk_tool
mkdir -p "$work/home2"
run VM=none HOMEFIELD_HOME="$work/home2" -- --remove-tool
record "HOMEFIELD_HOME names the install dir: the other copy is not touched" "0/there/there" "$rc/$([ -e "$share" ] && echo there || echo gone)/$([ -e "$bin/homefield" ] && echo there || echo gone)"
rm -rf "$share" "$bin" "$work/home2"

echo "unknown option:"
fresh
run -- --bogus
record "is refused" "1/yes" "$rc/$(has "$out" 'reset: unknown option --bogus')"

# ── the install side: the record is written when the group is created ────────
echo "install records the group it creates:"
cat >"$work/harness-install.sh" <<'EOF'
HOMEFIELD_SOURCE_ONLY=1
. "$ROOT_DIR/bin/homefield"
check_host() { :; }
cmd_preflight() { :; }
vm_lookup() { VM_STATUS=""; }
default_name() { echo test-runner; }
# The first thing install does after the group step: the VM. The record has to
# be there by now, whatever happens to the VM.
ensure_vm() { echo "at-vm=$(cat "$(state_file)" 2>/dev/null || echo none)"; exit 3; }
if [ -n "${CALL_ENSURE_GROUP:-}" ]; then
  ACCOUNT_MODE="${MODE:-org}"
  ensure_group "$CALL_ENSURE_GROUP" "${GROUP:-homefield-ci}"
  echo "state=$GROUP_STATE"
else
  cmd_install --url https://github.com/acme --org
fi
EOF
irun() {
  local envs=()
  while [ $# -gt 0 ]; do envs+=("$1"); shift; done
  : >"$work/log"
  rm -rf "$state"
  out="$(env -i PATH="$stubs:$PATH" HOME="$work/home" LOG="$work/log" ROOT_DIR="$ROOT" GH_GROUPS_FILE="$work/groups-none" \
    HOMEFIELD_INSTANCE=resettest HOMEFIELD_STATE_DIR="$state" "${envs[@]+"${envs[@]}"}" \
    "$BASH" "$work/harness-install.sh" 2>&1 </dev/null)"
  rc=$?
}
# The stub gh answers a POST with the new group, as GitHub does (compact JSON).
cat >"$stubs/gh" <<'EOF'
#!/bin/sh
echo "gh $*" >>"$LOG"
case "$*" in
  *"-X POST"*)
    if [ "${GH_POST_BODY+set}" = set ]; then printf '%s' "$GH_POST_BODY"; else printf '%s' '{"id":7,"name":"homefield-ci","visibility":"selected"}'; fi
    ;;
  *runner-groups*) cat "$GH_GROUPS_FILE" ;;
  *actions/runners*) ;;
esac
EOF
chmod +x "$stubs/gh"
printf 'Default\tall\tfalse\t1\n' >"$work/groups-none"
irun
record "install creates the group, and the record is there before the VM is touched" "3/yes/at-vm=group_created=acme/homefield-ci/7" "$rc/$(has "$out" 'created runner group homefield-ci')/$(echo "$out" | grep '^at-vm=')"
record "...the file holds exactly that line" "group_created=acme/homefield-ci/7" "$(cat "$(state_file)")"
irun CALL_ENSURE_GROUP=https://github.com/acme GROUP="Local CI"
record "a group name with a space is recorded whole" "group_created=acme/Local CI/7" "$(cat "$(state_file)")"
irun CALL_ENSURE_GROUP=https://github.com/acme "GH_POST_BODY=null"
record "an id that cannot be read: the org and name are recorded, the id is empty" "group_created=acme/homefield-ci/" "$(cat "$(state_file)")"
mkdir -p "$state"
printf 'other=1\ngroup_created=old/old/1\n' >"$state/resettest.state"
out="$(env -i PATH="$stubs:$PATH" HOME="$work/home" LOG="$work/log" ROOT_DIR="$ROOT" GH_GROUPS_FILE="$work/groups-none" \
  HOMEFIELD_INSTANCE=resettest HOMEFIELD_STATE_DIR="$state" CALL_ENSURE_GROUP=https://github.com/acme \
  "$BASH" "$work/harness-install.sh" 2>&1 </dev/null)"
record "a later creation replaces the record and keeps other keys" "other=1/group_created=acme/homefield-ci/7" "$(paste -sd/ "$(state_file)")"
printf 'Default\tall\tfalse\t1\nhomefield-ci\tselected\tfalse\t7\n' >"$work/groups-exist"
for mode in "narrow:groups-exist:org:homefield-ci" "default:groups-exist:org:Default" "personal:groups-exist:personal:homefield-ci"; do
  IFS=: read -r want file m g <<<"$mode"
  irun CALL_ENSURE_GROUP=https://github.com/acme GROUP="$g" MODE="$m" GH_GROUPS_FILE="$work/$file"
  record "a group that was already there ($want) is never recorded" "state=$want/no-state" "$(echo "$out" | grep '^state=')/$(has_state)"
done
printf 'Default\tall\tfalse\t1\nhomefield-ci\tall\tfalse\t7\n' >"$work/groups-wide"
irun CALL_ENSURE_GROUP=https://github.com/acme GH_GROUPS_FILE="$work/groups-wide"
record "...nor a wider one that was warned about" "state=wide/no-state" "$(echo "$out" | grep '^state=')/$(has_state)"
irun CALL_ENSURE_GROUP=https://github.com/acme/app MODE=
record "...nor a repository URL (no groups)" "state=repo/no-state" "$(echo "$out" | grep '^state=')/$(has_state)"
irun CALL_ENSURE_GROUP=https://github.com/acme HOMEFIELD_STATE_DIR=/dev/null/nope
record "a record that cannot be written: warned, the install goes on, the group is named" "state=created/yes/yes" "$(echo "$out" | grep '^state=')/$(has "$out" 'could not record that this install created the runner group homefield-ci')/$(has "$out" 'remove it by hand')"

summary
