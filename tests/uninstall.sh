#!/usr/bin/env bash
# `homefield uninstall` on a registered runner (#60): the service is
# uninstalled before the registration is removed, so when GitHub refuses the
# removal the runner has to get its service back, not only a start command for
# a unit that is gone. And a guest that cannot be asked stops the command
# with nothing changed, instead of reading as "no": whether the runner is
# registered (#80, or the VM would be deleted), whether a job is running and
# whether the runner has a service (#82, or a live job would be stopped).
#
# The real cmd_uninstall runs, with the guest side run here in a scratch
# runner directory: svc.sh, config.sh, systemctl, sudo and limactl are stubs,
# and the VM helpers are functions. pgrep answers from JOB (idle, running,
# broken), never from this machine, which is itself a runner. The systemctl
# stub starts only a unit that exists, as the real one does. Nothing reaches GitHub or a VM.
#
# Run:  bash tests/uninstall.sh
# shellcheck disable=SC2016  # the stub bodies expand when they run, not when defined
set -uo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
stubs="$work/stubs"
home="$work/runner"
mkdir -p "$stubs"
unit="actions.runner.acme.test.service"

stub() { printf '#!/usr/bin/env bash\n%s\n' "$2" >"$stubs/$1"; chmod +x "$stubs/$1"; }
# sudo [-n] [-u user] [--preserve-env=...] <command...>: the command, as this user.
stub sudo 'while [ $# -gt 0 ]; do case "$1" in -u) shift 2 ;; -n|--preserve-env=*) shift ;; *) break ;; esac; done
exec "$@"'
stub limactl 'echo "limactl $*" >>"$LOG"'
stub pgrep 'case "${JOB:-idle}" in running) exit 0 ;; idle) exit 1 ;; *) exit 3 ;; esac'
# The unit is a file in the runner directory; it is active while a marker is.
stub systemctl 'echo "systemctl $*" >>"$LOG"
case "$1" in
  stop) rm -f "$HOME_DIR/active" ;;
  start) [ -e "$HOME_DIR/unit" ] || { echo "Unit $2 not found." >&2; exit 5; }; : >"$HOME_DIR/active" ;;
esac'

# What a runner directory has: the scripts the runner ships, with the service
# installed and the runner registered.
fresh() {
  rm -rf "${work:?}/runner" "$work/log"
  mkdir -p "$home"
  : >"$home/.runner"
  echo "$unit" >"$home/.service"
  : >"$home/unit"
  : >"$home/active"
  cat >"$home/svc.sh" <<'EOF'
#!/bin/sh
echo "svc.sh $*" >>"$LOG"
case "$1" in
  uninstall) rm -f "$HOME_DIR/unit" "$HOME_DIR/.service" ;;
  install)
    [ "${FAIL_INSTALL:-}" != 1 ] || { echo "svc.sh: injected failure" >&2; exit 1; }
    : >"$HOME_DIR/unit"
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

# run: cmd_uninstall, in a shell of its own so its EXIT trap runs. It keeps the
# VM unless UNINSTALL_ARGS is set (to nothing, to delete it). The guest answers
# unless GUEST_MODE is fail (the call fails) or silent (it succeeds and says
# nothing), or FAIL_ON is set and the call's arguments contain it. The probes
# are the real ones.
cat >"$work/harness.sh" <<EOF
HOMEFIELD_SOURCE_ONLY=1
. "$ROOT/bin/homefield"
RUNNER_HOME="$home"
check_host() { :; }
vm_status() { echo Running; }
runner_setting() { echo https://github.com/acme; }
get_token() { echo tok; }
guest() {
  case "\${GUEST_MODE:-}" in fail) return 1 ;; silent) return 0 ;; esac
  [ -z "\${FAIL_ON:-}" ] || case "\$*" in *"\$FAIL_ON"*) return 1 ;; esac
  "\$@"
}
guest_stdin() { "\$@"; }
cmd_uninstall \${UNINSTALL_ARGS---keep-vm}
EOF
run() {
  out="$(PATH="$stubs:$PATH" LOG="$work/log" HOME_DIR="$home" "$@" bash "$work/harness.sh" 2>&1 </dev/null)"
  rc=$?
}
has() { case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac; }
state() {
  printf '%s/%s/%s/%s' "$([ -e "$home/.runner" ] && echo registered || echo removed)" \
    "$([ -e "$home/unit" ] && echo unit || echo no-unit)" "$([ -e "$home/.service" ] && echo .service || echo no-.service)" \
    "$([ -e "$home/active" ] && echo active || echo stopped)"
}
logged() { grep -c -e "$1" "$work/log" || true; }

echo "removal works:"
fresh
run env
record "uninstall succeeds" "0" "$rc"
record "...deregistered, service uninstalled, runner left stopped" "removed/no-unit/no-.service/stopped" "$(state)"
record "...the token reached config.sh through its environment" "1" "$(logged 'config.sh remove token-in-env=yes')"
record "...no start was attempted" "0" "$(logged 'systemctl start')"

echo "GitHub refuses the removal:"
fresh
run env FAIL_REMOVE=1
record "uninstall fails" "1" "$rc"
record "...still registered, with its service back and running" "registered/unit/.service/active" "$(state)"
record "...the service was reinstalled once, and started" "1/1" "$(logged 'svc.sh install runner')/$(logged 'systemctl start')"
record "...the message says so" "yes" "$(has "$out" 'starting '"$unit"' again')"

echo "removal and the reinstall both fail:"
fresh
run env FAIL_REMOVE=1 FAIL_INSTALL=1
record "uninstall fails" "1" "$rc"
record "...still registered, no service, and says it could not start it" "registered/no-unit/no-.service/stopped/yes" "$(state)/$(has "$out" 'could not start')"

echo "no service installed (provisioning never finished):"
fresh
rm -f "$home/unit" "$home/.service" "$home/active"
run env FAIL_REMOVE=1
record "uninstall fails" "1" "$rc"
record "...no service is installed that was not there" "0" "$(logged 'svc.sh')"
rm -f "$home/.runner"
fresh
rm -f "$home/unit" "$home/.service" "$home/active"
run env
record "removal works without a service" "0/removed" "$rc/$([ -e "$home/.runner" ] && echo registered || echo removed)"

echo "the VM is deleted with the registration removed:"
fresh
run env UNINSTALL_ARGS=
record "uninstall succeeds" "0" "$rc"
record "...deregistered, then the VM was deleted once" "removed/1" "$(state | cut -d/ -f1)/$(logged 'limactl delete --force')"

echo "not registered, as the guest says:"
fresh
rm -f "$home/.runner"
run env UNINSTALL_ARGS=
record "uninstall succeeds" "0" "$rc"
record "...says there is nothing to deregister, and deletes the VM" "yes/1" "$(has "$out" 'is not registered; nothing to deregister')/$(logged 'limactl delete --force')"
record "...without running config.sh" "0" "$(logged 'config.sh')"

echo "the guest cannot be asked whether it is registered (#80):"
for mode in fail silent; do
  fresh
  run env UNINSTALL_ARGS= GUEST_MODE=$mode
  record "$mode: uninstall fails" "1" "$rc"
  record "...says it could not ask, not that nothing is registered" "yes/no" "$(has "$out" 'could not ask VM')/$(has "$out" 'nothing to deregister')"
  record "...the VM is neither stopped nor deleted, the registration is untouched" "0/0/0/registered" "$(logged 'limactl delete')/$(logged 'limactl stop')/$(logged 'config.sh')/$(state | cut -d/ -f1)"
done

echo "a job is running:"
fresh
run env JOB=running
record "uninstall refuses" "1/yes" "$rc/$(has "$out" 'a job is running')"
record "...the runner was not stopped" "0/registered/unit/.service/active" "$(logged 'systemctl')/$(state)"

echo "the guest cannot be asked about the job, the service or its name (#82):"
for case_ in "JOB=broken:whether a job is running" "FAIL_ON=pgrep:whether a job is running" \
  "FAIL_ON=.service:whether the runner has a service" "FAIL_ON=sudo cat:read the runner's service name"; do
  fresh
  run env "${case_%%:*}"
  record "${case_%%:*}: uninstall fails" "1" "$rc"
  record "...saying what it could not ask" "yes/no" "$(has "$out" "${case_#*:}")/$(has "$out" 'a job is running on')"
  record "...nothing was stopped, deregistered or deleted" "0/0/0/registered/unit/.service/active" \
    "$(logged 'systemctl')/$(logged 'config.sh')/$(logged 'limactl delete')/$(state)"
done

summary
